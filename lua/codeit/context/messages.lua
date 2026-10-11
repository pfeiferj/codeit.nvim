local M = {}
local context_review = require('codeit.context.review')
local compaction = require('codeit.context.compaction')
local approval = require('codeit.tools.approval')
local history = require('codeit.chat.storage')
local context_files = require('codeit.context.files')

function M.attach(api, session, helpers)
  local M = api
  function helpers.current_prompt()
    return session.messages[1] and session.messages[1].content or session.session_prompt or session.config.system_prompt
  end

  function helpers.redact_disabled_skill_results(items)
    local states = {}
    for _, entry in ipairs(context_files.entries(session.workspace, approval.workspace_trust(session.workspace),
      session.context_paths, session.selected_skills)) do
      if entry.kind == 'skill' then states[entry.name] = entry.state end
    end
    local skill_calls, result = {}, {}
    for _, message in ipairs(items) do
      local projected = message
      if message.role == 'assistant' and type(message.tool_calls) == 'table' then
        for index, call in ipairs(message.tool_calls) do
          local fn = type(call) == 'table' and call['function']
          if type(fn) == 'table' and fn.name == 'load_skill' then
            local ok, args = pcall(vim.json.decode, fn.arguments or '')
            local state = (ok and type(args) == 'table' and states[args.name]) or 'off'
            skill_calls[call.id] = state
            if state == 'off' then
              if projected == message then projected = vim.deepcopy(message) end
              projected.tool_calls[index]['function'].arguments = '{}'
            end
          end
        end
      end
      local state = message.role == 'tool' and skill_calls[message.tool_call_id]
      if state and type(message.content) == 'string'
        and message.content:match('^Skill [^\n]* %((.-)%)%:\n') then
        projected = vim.tbl_extend('force', {}, message, {
          content = state == 'off' and 'Skill disabled for this chat.'
            or state == 'active' and 'Skill activation recorded; current instructions are provided separately in context.'
            or 'Skill instructions unloaded for this chat.',
        })
      end
      result[#result + 1] = projected
    end
    return result
  end

  function helpers.validate_context_summary()
    if not session.context_summary then return end
    local current = context_files.skill_snapshot(session.workspace or history.workspace(),
      approval.workspace_trust(session.workspace), session.context_paths, session.selected_skills)
    local valid = type(session.context_summary_skills) == 'table'
    if valid then
      for path, digest in pairs(session.context_summary_skills) do
        if current[path] ~= digest then valid = false; break end
      end
    end
    if not valid then
      -- Restore the original transcript rather than keep a summary influenced by unloaded instructions.
      session.context_summary, session.compacted_until, session.context_summary_skills = nil, nil, nil
      session.review_revision = session.review_revision + 1
      helpers.save()
    end
  end

  function helpers.request_messages()
    helpers.validate_context_summary()
    local result = {}
    if session.messages[1] then result[1] = session.messages[1] end
    vim.list_extend(result, context_files.messages(session.workspace or history.workspace(),
      approval.workspace_trust(session.workspace), session.context_paths, session.selected_skills))
    if session.context_summary and session.compacted_until then
      result[#result + 1] = compaction.summary_message(session.context_summary)
    end
    vim.list_extend(result, (context_review.project(session.messages, session.turn_reviews or session.context_reviews,
      session.context_summary and session.compacted_until and session.compacted_until + 1 or 2)))
    return helpers.redact_disabled_skill_results(result)
  end

  function helpers.message_tokens(message)
    return compaction.tokens(message)
  end

  function helpers.estimate_context()
    local count = 0
    for _, message in ipairs(helpers.request_messages()) do count = count + helpers.message_tokens(message) end
    session.context_tokens = count
    session.context_estimated = true
  end
end

return M
