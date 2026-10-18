local M = {}
local compaction = require('codeit.context.compaction')
local providers = require('codeit.providers')
local tools = require('codeit.tools')
local approval = require('codeit.tools.approval')
local history = require('codeit.chat.storage')
local cost_breakdown = require('codeit.cost_breakdown')
local context_files = require('codeit.context.files')
local settings = require('codeit.settings')
local tool_limit_prompt = require('codeit.tools.limit_prompt')
local tool_arguments = require('codeit.tools.arguments')
local stream_idle_ms = 10000

function M.attach(api, session, helpers)
  local M = api
  function helpers.request(round, id, skip_auto, detected_limit, limit_checked, budget)
    local billed_turn = session.current_turn
    budget = budget or { limit = session.config.max_tool_rounds }
    local function active()
      if id ~= session.generation then return false end
      if session.workspace ~= history.workspace() then helpers.sync_workspace(); helpers.render(); return false end
      return true
    end
    if not active() then return end
    local resume_round = round
    helpers.interrupt = function(text, reason)
      if not session.busy or not active() then return false end
      local turn, reviews = session.current_turn, session.turn_reviews
      helpers.stop(reason or 'Interrupted by background task completion')
      session.current_turn, session.turn_reviews = turn, reviews
      table.insert(session.messages, { role = 'user', content = text })
      session.busy = true
      helpers.save()
      helpers.request(resume_round, session.generation, false, nil, nil, budget)
      return true
    end
    helpers.validate_context_summary()
    if not skip_auto and not budget.long_context and session.config.max_context_tokens == nil and not limit_checked
      and type(providers.context_limit) == 'function' then
      return providers.context_limit(helpers.request_config(), function(limit, err)
        if id ~= session.generation then return end
        if err then vim.notify('codeit: could not detect model context limit: ' .. tostring(err), vim.log.levels.WARN) end
        helpers.request(round, id, false, limit, true, budget)
      end)
    end
    local specs = budget.declined and {} or tools.request_specs(session.workspace, approval.workspace_trust(session.workspace), session.selected_skills)
    local limit = budget.long_context_limit or (session.config.max_context_tokens == nil and detected_limit or session.config.max_context_tokens)
    local selected_config = budget.long_context or helpers.request_config()
    if not skip_auto then
      local checkpoint = helpers.auto_compact_checkpoint(limit, specs)
      if checkpoint then
        return helpers.compact_through(checkpoint, id, function(err)
          if err then vim.notify('codeit: ' .. err, vim.log.levels.WARN) end
          helpers.request(round, id, true, limit, true, budget) -- Do not retry compaction in this request.
        end, limit)
      end
    end
    if limit then
      local total = helpers.message_tokens(specs)
      for _, message in ipairs(helpers.request_messages()) do total = total + helpers.message_tokens(message) end
      if total >= compaction.input_budget(session.config.compaction, limit) then
        local fallback = settings.preset_config(session.config, 'long_context', helpers.model())
        if not budget.long_context and not budget.fallback_checked and not vim.deep_equal(selected_config, fallback)
          and type(providers.context_limit) == 'function' then
          budget.fallback_checked = true
          helpers.set_status('Checking long context model budget…')
          return providers.context_limit(fallback, function(fallback_limit)
            if not active() then return end
            if fallback_limit and total < compaction.input_budget(session.config.compaction, fallback_limit) then
              budget.long_context, budget.long_context_limit = fallback, fallback_limit
            end
            helpers.request(round, id, true, limit, true, budget)
          end)
        end
        vim.notify('codeit: context exceeds the safe prompt budget; fixed instructions or the active turn cannot be compacted', vim.log.levels.WARN)
      end
    end
    -- Tool completion carries activity across the provider requests in this turn.
    local response_pending, last_stream_activity = true, budget.last_tool_activity
    if last_stream_activity and (vim.uv.hrtime() - last_stream_activity) / 1e6 >= stream_idle_ms then
      last_stream_activity = nil
    end
    session.last_agent_activity = budget.last_tool_activity or vim.uv.hrtime()
    helpers.set_status(last_stream_activity and 'Thinking' or 'Waiting')
    -- Treat brief gaps between chunks as streaming, but show longer provider pauses.
    local function check_stream_idle()
      if not response_pending or not active() then return end
      local remaining = stream_idle_ms - (vim.uv.hrtime() - last_stream_activity) / 1e6
      if remaining > 0 then
        vim.defer_fn(check_stream_idle, math.ceil(remaining))
      else
        last_stream_activity = nil
        helpers.set_status('Waiting')
      end
    end
    if last_stream_activity then check_stream_idle() end
    local function stream_activity()
      if not response_pending or not active() then return end
      local was_idle = last_stream_activity == nil
      last_stream_activity = vim.uv.hrtime()
      session.last_agent_activity = last_stream_activity
      if was_idle then vim.defer_fn(check_stream_idle, stream_idle_ms) end
      session.status = 'Thinking'
      if session.stream_render_pending then return end
      session.stream_render_pending = true
      vim.defer_fn(function()
        session.stream_render_pending = false
        if active() then helpers.render() end
      end, 50)
    end
    local advertised = vim.json.encode(context_files.messages(session.workspace, approval.workspace_trust(session.workspace),
      session.context_paths, session.selected_skills))
    local subagent_workspace, subagent_chat = session.workspace, session.chat_id
    local on_auto_approval = require('codeit.chat.auto_approvals').recorder(session, helpers, subagent_workspace, subagent_chat)
    local subagent_config = helpers.request_config('subagent')
    subagent_config.max_tool_rounds = session.config.max_subagent_tool_rounds
    subagent_config.tool_json_healing = session.config.tool_json_healing
    local subagent_turn_index
    for index, turn in ipairs(session.turn_costs) do if turn == billed_turn then subagent_turn_index = index end end
    local function subagent_usage(usage)
      if session.workspace == subagent_workspace and session.chat_id == subagent_chat then
        return helpers.record_usage(usage, 'subagent', subagent_config.provider, session.turn_costs[subagent_turn_index])
      end
      -- Background billing belongs to the originating chat, never the active one.
      local chat = history.load(subagent_workspace, subagent_chat)
      if not chat then return end
      local amount = helpers.usage_number(usage and usage.cost)
      local input, output = helpers.usage_number(usage and usage.prompt_tokens), helpers.usage_number(usage and usage.completion_tokens)
      local function add(target)
        target.cost = (target.cost or 0) + (amount or 0)
        target.missing_cost = (target.missing_cost or 0) + (amount and 0 or 1)
        target.cost_by_function = target.cost_by_function or {}
        cost_breakdown.add(target.cost_by_function, 'subagent', amount, input, output)
      end
      add(chat)
      local turn = chat.turn_costs and chat.turn_costs[subagent_turn_index]
      if turn then add(turn) end
      chat.tokens_in, chat.tokens_out = (chat.tokens_in or 0) + (input or 0), (chat.tokens_out or 0) + (output or 0)
      chat.missing_in, chat.missing_out = chat.missing_in or not input, chat.missing_out or not output
      history.save(subagent_workspace, subagent_chat, chat)
    end
    providers.chat(selected_config, helpers.request_messages(), specs, function(message, err, usage)
      response_pending = false
      if not active() then return end
      session.stream_preview = nil
      if err then return helpers.fail(err) end
      helpers.record_usage(usage, 'main_chat', selected_config.provider, billed_turn)
      local calls = message.tool_calls
      if type(calls) == 'table' then
        local seen = {}
        for _, call in ipairs(calls) do
          if type(call) ~= 'table' or type(call.id) ~= 'string' or call.id == '' or seen[call.id]
            or type(call['function']) ~= 'table' or type(call['function'].name) ~= 'string' then
            return helpers.fail('Malformed tool call from provider')
          end
          seen[call.id] = true
        end
      end
      local tool_log = require('codeit.tools.log')
      local tool_log_entries, decoded_arguments = {}, {}
      for index, call in ipairs(type(calls) == 'table' and calls or {}) do
        local fn = call['function']
        local raw = fn.arguments
        local arguments, _, canonical = tool_arguments.decode(raw, session.config.tool_json_healing)
        decoded_arguments[index] = arguments
        if canonical then fn.arguments = canonical end
        tool_log_entries[index] = tool_log.start(fn.name, arguments, raw)
        tool_log_entries[index].tool_call_id = call.id
      end
      -- Hold this response while the user decides, before retaining or executing
      -- any calls. Reuse it on approval rather than asking the provider again.
      local function process()
        if not active() then return end
        if budget.declined and type(calls) == 'table' and #calls > 0 then
          return helpers.fail('Tool call limit reached; provider requested tools after they were disabled')
        end
        local batch_start = #session.messages + 1
        table.insert(session.messages, { role = 'assistant', content = message.content or vim.NIL, tool_calls = calls,
          _copilot_reasoning = message._copilot_reasoning, _codex_reasoning = message._codex_reasoning,
          reasoning_details = message.reasoning_details })
        helpers.save()
        helpers.render()
        if type(calls) ~= 'table' or #calls == 0 then
          helpers.complete()
          return helpers.review_turn()
        end
        resume_round = round + 1
        local user_request
        for i = batch_start - 1, 1, -1 do
          if session.messages[i].role == 'user' then user_request = session.messages[i].content; break end
        end
        local function review(history, callback, feature, review_active)
          local selected_config = helpers.request_config(feature or 'tool_review')
          local function active_review() return id == session.generation and (not review_active or review_active()) end
          local function respond(message, err)
            if not active_review() then return end
            if err then return callback(nil, err) end
            local content = message and message.content
            if type(content) == 'table' then
              local parts = {}
              for _, part in ipairs(content) do
                if part.type == 'text' then parts[#parts + 1] = part.text or '' end
              end
              content = table.concat(parts, '\n')
            end
            callback(type(content) == 'string' and content or 'No reviewer response')
          end
          local function usage(result) helpers.record_usage(result, feature or 'tool_review', selected_config.provider, billed_turn) end
          if feature == 'tool_assessment' then
            providers.chat(selected_config, history, {}, function(message, err, result)
              if id ~= session.generation then return end
              if not err then usage(result) end
              respond(message, err)
            end, nil, active_review)
          else
            require('codeit.tools.reviewer').chat(selected_config, history, session.messages, respond, active_review, usage)
          end
        end
        local function decide(state, questions, callback, assessment_active)
          local config = helpers.request_config('tool_assessment')
          local function live() return active() and (not assessment_active or assessment_active()) end
          providers.decisions(config, state, questions, function(answers, err, usage)
            if not live() then return end
            if not err then helpers.record_usage(usage, 'tool_assessment', config.provider, billed_turn) end
            callback(answers, err)
          end, live)
        end
        local function prepare(path)
          if type(path) == 'string' and path ~= '' and not vim.tbl_contains(session.context_paths, path) then
            session.context_paths[#session.context_paths + 1] = path
          end
          return advertised == vim.json.encode(context_files.messages(session.workspace, approval.workspace_trust(session.workspace),
            session.context_paths, session.selected_skills))
        end
        local assessments = {}
        for index, call in ipairs(calls) do
          local fn = type(call) == 'table' and call['function']
          if type(fn) == 'table' then
            local args = decoded_arguments[index]
            if fn.name == 'ask_user' then break end -- Later calls may be invalidated by the answer.
            if args and type(fn.name) == 'string' and not tools.validate(fn.name, args) then
              local prefetched, assessment = pcall(approval.prefetch, fn.name, args,
                { user_request = user_request, review = review, decide = decide, source_buffer = session.source },
                function() return id == session.generation end)
              if prefetched then assessments[index] = assessment end
            end
          end
        end
        local approval_round = {}
        local function next_call(index)
          if id ~= session.generation then return end
          if index > #calls then return helpers.request(round + 1, id, false, nil, nil, budget) end
          local call = calls[index]
          if type(call) ~= 'table' or type(call.id) ~= 'string' or type(call['function']) ~= 'table' then
            return helpers.fail('Malformed tool call from provider')
          end
          local fn = call['function']
          helpers.set_status('Tool: ' .. tostring(fn.name))
          local args = decoded_arguments[index]
          tools.execute(fn.name, args, session.source, function(result, signal)
            if id ~= session.generation then return end
            if signal == 'cancel' then
              session.generation = session.generation + 1
              session.busy = false
              for i = #session.messages, batch_start, -1 do table.remove(session.messages, i) end
              for _, command_result in ipairs(session.command_results) do
                command_result.after_message = math.min(command_result.after_message, #session.messages)
              end
              helpers.save()
              return helpers.set_status('Task cancelled')
            end
            budget.last_tool_activity = vim.uv.hrtime()
            session.last_agent_activity = budget.last_tool_activity
            session.status = 'Thinking'
            table.insert(session.messages, { role = 'tool', tool_call_id = call.id, content = result })
            if type(result) == 'string' and not result:match('^Error:') and not result:match('^Rejected') then
              local path
              if vim.tbl_contains({ 'read_file', 'read_loaded_buffer', 'read_source_buffer', 'read_window_buffer',
                'edit_file', 'edit_loaded_buffer', 'edit_source_buffer', 'create_file',
                'save_buffer', 'save_loaded_buffer', 'save_source_buffer' }, fn.name) then
                path = args and args.path
                if path == nil and fn.name ~= 'create_file' then
                  local buffer = args and (args.buffer_id or (fn.name == 'read_window_buffer'
                    and require('codeit.ui.managed_tab').buffer(args.window_id)) or session.source)
                  if require('codeit.file_buffer').valid(buffer) then path = vim.api.nvim_buf_get_name(buffer) end
                end
              end
              if type(path) == 'string' and path ~= '' and not vim.tbl_contains(session.context_paths, path) then
                session.context_paths[#session.context_paths + 1] = path
              end
              if fn.name == 'load_skill' and args and type(args.name) == 'string' then
                local loaded_path = result:match('^Skill [^\n]* %((.-)%)%:\n')
                if loaded_path then
                  for index = #session.selected_skills, 1, -1 do
                    if type(session.selected_skills[index]) == 'table' and session.selected_skills[index].name == args.name then
                      table.remove(session.selected_skills, index)
                    end
                  end
                  session.selected_skills[#session.selected_skills + 1] = { name = args.name, path = loaded_path, arguments = args.arguments or '' }
                end
              end
            end
            local answered = fn.name == 'ask_user' and type(result) == 'string' and result:sub(1, 1) == '{'
            if not prepare() or answered then
              -- Calls planned before an instruction update or clarification answer
              -- must be reconsidered, while preserving matching tool results.
              for remaining = index + 1, #calls do
                table.insert(session.messages, { role = 'tool', tool_call_id = calls[remaining].id,
                  content = answered and 'Deferred: a user clarification was answered. Review the answer before reissuing this call; it was not executed.'
                    or 'Deferred: project instructions or selected skills changed. Review the new context and reissue this call if still appropriate; it was not executed.' })
              end
              helpers.save()
              helpers.render()
              return helpers.request(round + 1, id, false, nil, nil, budget)
            end
            helpers.save()
            helpers.render()
            next_call(index + 1)
          end, function() return id == session.generation and session.workspace == history.workspace() end, {
            on_auto_approval = on_auto_approval, tool_call_id = call.id,
            user_request = user_request,
            approval_round = approval_round,
            background_origin = { workspace = session.workspace, chat_id = session.chat_id, turn = billed_turn },
            subagent_config = subagent_config,
            subagent_messages = helpers.request_messages(),
            subagent_usage = subagent_usage,
            tool_log_entry = tool_log_entries[index],
            review = review,
            decide = decide,
            assessment = assessments[index],
            prepare = prepare,
            read_versions = session.read_versions,
            skill_selections = session.selected_skills,
          })
        end
        next_call(1)
      end
      if not budget.declined and type(calls) == 'table' and #calls > 0 and round >= budget.limit then
        helpers.set_status('Tool limit reached; waiting for your decision…')
        return tool_limit_prompt.show(session.config.max_tool_rounds, active, function(additional)
          if not active() then return end
          if additional then
            budget.limit = round + additional
            return process()
          end
          -- Balance every declined call so future requests and saved history
          -- remain valid, then allow one tool-free final response.
          table.insert(session.messages, { role = 'assistant', content = message.content or vim.NIL, tool_calls = calls,
            _copilot_reasoning = message._copilot_reasoning, _codex_reasoning = message._codex_reasoning,
            reasoning_details = message.reasoning_details })
          for index, call in ipairs(calls) do
            local result = 'Error: Tool call limit reached. The user declined additional tool rounds. This call was not executed; finish without tools.'
            tool_log.finish(tool_log_entries[index], result)
            table.insert(session.messages, { role = 'tool', tool_call_id = call.id, content = result })
          end
          helpers.save()
          helpers.render()
          budget.declined = true
          helpers.request(round, id, true, nil, nil, budget)
        end)
      end
      process()
    end, function(text)
      if not response_pending or not active() then return end
      session.stream_preview = text
      stream_activity()
    end, active, stream_activity)
  end
end

return M
