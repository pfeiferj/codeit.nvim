local M = {}
local context_review = require('codeit.context.review')
local compaction = require('codeit.context.compaction')
local providers = require('codeit.providers')
local approval = require('codeit.tools.approval')
local history = require('codeit.chat.storage')
local context_files = require('codeit.context.files')
local settings = require('codeit.settings')

function M.attach(api, session, helpers)
  local M = api
  function helpers.compact_through(checkpoint, id, done, main_limit, instructions)
    local billed_turn = session.current_turn
    local started, before = vim.uv.hrtime(), 0
    for _, message in ipairs(helpers.request_messages()) do before = before + helpers.message_tokens(message) end
    local selected_workspace = session.workspace
    local function active()
      return id == session.generation and session.workspace == selected_workspace and history.workspace() == selected_workspace
    end
    local summary_skills = context_files.skill_snapshot(session.workspace, approval.workspace_trust(session.workspace),
      session.context_paths, session.selected_skills)
    local completed, indices = context_review.project(session.messages, session.turn_reviews or session.context_reviews,
      (session.compacted_until or 1) + 1, checkpoint)
    completed = vim.deepcopy(helpers.redact_disabled_skill_results(completed))
    for _, message in ipairs(completed) do
      message._copilot_reasoning, message._codex_reasoning = nil, nil
    end
    local groups, group = {}, {}
    for i, message in ipairs(completed) do
      group[#group + 1] = vim.json.encode(message)
      local original = session.messages[indices[i]]
      if original.role == 'assistant' and (type(original.tool_calls) ~= 'table' or #original.tool_calls == 0) then
        groups[#groups + 1] = table.concat(group, '\n')
        group = {}
      end
    end
    helpers.set_status('Checking compaction model budget…')
    local selected_config = helpers.request_config('compaction')
    local target = compaction.summary_budget(session.config.compaction, main_limit)
    local position, passes, billed = 1, 0, 0
    local previous = session.context_summary
    local function finish(err)
      if not active() then return end
      session.context_stats.compactions[#session.context_stats.compactions + 1] = {
        before_tokens = before, after_tokens = err and before or session.context_tokens, checkpoint = checkpoint,
        duration_ms = (vim.uv.hrtime() - started) / 1000000, passes = passes,
        cost = billed, error = err, main_requests = session.context_stats.main_requests,
      }
      helpers.save()
      done(err and ('Could not compact context: ' .. tostring(err)) or nil)
    end
    local fallback_checked = false
    local function run(limit)
      if not active() then return end
      if limit then target = math.min(target, math.max(1, math.floor(limit * 0.15))) end
      local prompt = { role = 'system', content = compaction.prompt(target, instructions) }
      local output_cap = math.ceil(target * 1.25)
      local input_limit = limit and math.max(1, math.floor(limit * 0.95 - output_cap)) or math.huge
      local function step()
        if not active() then return end
        local transcript = previous and ('Previous summary:\n' .. previous .. '\n') or ''
        local first = position
        while position <= #groups do
          local candidate = transcript .. groups[position] .. '\n'
          if helpers.message_tokens(prompt) + helpers.message_tokens({ role = 'user', content = candidate }) > input_limit then break end
          transcript = candidate
          position = position + 1
        end
        if position == first then
          local err = 'a completed turn exceeds the compaction model input budget'
          local fallback = settings.preset_config(session.config, 'long_context', helpers.model())
          if fallback_checked or (selected_config.provider == fallback.provider and selected_config.model == fallback.model
            and vim.deep_equal(selected_config.options, fallback.options))
            or type(providers.context_limit) ~= 'function' then return finish(err) end
          fallback_checked = true
          helpers.set_status('Checking long context model budget…')
          return providers.context_limit(fallback, function(fallback_limit)
            if not active() then return end
            -- Unknown metadata is not evidence that the fallback can fit.
            if not fallback_limit then return finish(err) end
            local fallback_target = math.min(target, math.max(1, math.floor(fallback_limit * 0.15)))
            local fallback_prompt = { role = 'system', content = compaction.prompt(fallback_target, instructions) }
            local candidate = transcript .. groups[position] .. '\n'
            local fallback_budget = math.max(1, math.floor(fallback_limit * 0.95 - math.ceil(fallback_target * 1.25)))
            if helpers.message_tokens(fallback_prompt) + helpers.message_tokens({ role = 'user', content = candidate }) > fallback_budget then
              return finish(err)
            end
            selected_config = fallback
            run(fallback_limit)
          end)
        end
        passes = passes + 1
        helpers.set_status('Compacting context…')
        selected_config.max_output_tokens = output_cap
        providers.chat(selected_config, { prompt, { role = 'user', content = transcript } }, {}, function(message, err, usage)
          if not active() then return end
          if usage or not err then
            helpers.record_usage(usage, 'compaction', selected_config.provider, billed_turn)
            billed = billed + (helpers.usage_number(usage and usage.cost) or 0)
          end
          local content = message and message.content
          if type(content) == 'table' then
            local parts = {}
            for _, part in ipairs(content) do
              if type(part) == 'table' and part.type == 'text' and type(part.text) == 'string' then
                parts[#parts + 1] = part.text
              end
            end
            content = table.concat(parts, '\n')
          end
          content = type(content) == 'string' and vim.trim(content) or ''
          if not err and content == '' then err = 'empty summary' end
          if not err and helpers.message_tokens(compaction.summary_message(content)) > target then err = 'summary exceeds its token budget' end
          if not err and #vim.json.encode(compaction.summary_message(content)) >= #transcript then
            err = 'summary does not reduce context'
          end
          if err then return finish(err) end
          previous = content
          if position <= #groups then return step() end
          session.context_summary, session.compacted_until = previous, checkpoint
          session.context_summary_skills = summary_skills
          session.context_reviews = vim.tbl_filter(function(review) return review.first > checkpoint end, session.context_reviews)
          if session.turn_reviews then
            session.turn_reviews = vim.tbl_filter(function(review) return review.first > checkpoint end, session.turn_reviews)
          end
          session.review_revision = session.review_revision + 1
          helpers.estimate_context()
          finish()
        end, nil, active)
      end
      step()
    end
    if type(providers.context_limit) == 'function' then
      providers.context_limit(selected_config, function(limit) run(limit) end)
    else
      run()
    end
  end

  function helpers.auto_compact_checkpoint(limit, specs)
    if not limit then return nil end
    local fixed = helpers.message_tokens(specs)
    for _, extra in ipairs(context_files.messages(session.workspace, approval.workspace_trust(session.workspace),
      session.context_paths, session.selected_skills)) do fixed = fixed + helpers.message_tokens(extra) end
    if session.messages[1] then fixed = fixed + helpers.message_tokens(session.messages[1]) end
    local projected, indices = context_review.project(session.messages, session.turn_reviews or session.context_reviews, (session.compacted_until or 1) + 1)
    return compaction.checkpoint(session.config.compaction, limit, fixed, session.context_summary,
      helpers.redact_disabled_skill_results(projected), indices, session.messages)
  end

  function M.compact(all, instructions)
    helpers.sync_workspace()
    if session.busy then
      vim.notify('codeit: wait for the current response before compacting', vim.log.levels.WARN)
      return
    end
    local last = session.messages[#session.messages]
    if not last or last.role ~= 'assistant' or (type(last.tool_calls) == 'table' and #last.tool_calls > 0) then
      vim.notify('codeit: finish a conversation turn before compacting', vim.log.levels.WARN)
      return
    end
    helpers.validate_context_summary()
    local checkpoint, retained = #session.messages, 0
    if all ~= true then
      checkpoint = nil
      for i = #session.messages, (session.compacted_until or 1) + 1, -1 do
        local message = session.messages[i]
        if message.role == 'assistant' and (type(message.tool_calls) ~= 'table' or #message.tool_calls == 0) then
          if retained >= session.config.compaction.manual_keep_turns then checkpoint = i; break end
          retained = retained + 1
        end
      end
    end
    if not checkpoint or checkpoint <= (session.compacted_until or 1) then
      vim.notify('codeit: no new conversation to compact', vim.log.levels.INFO)
      return
    end
    session.busy = true
    helpers.compact_through(checkpoint, session.generation, function(err)
      if err then return helpers.fail(err) end
      session.busy = false
      helpers.set_status('Context compacted')
    end, nil, instructions)
  end
end

return M
