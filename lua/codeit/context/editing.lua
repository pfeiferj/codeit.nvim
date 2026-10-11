local M = {}
local ui = require('codeit.ui')
local approval = require('codeit.tools.approval')
local history = require('codeit.chat.storage')
local context_files = require('codeit.context.files')
local context_files_picker = require('codeit.context.picker')

function M.attach(api, session, helpers)
  local M = api
  function helpers.context_guard()
    local selected_workspace, selected_chat = session.workspace, session.chat_id
    local view_generation, snapshot = session.generation, vim.json.encode({
      messages = session.messages, summary = session.context_summary or vim.NIL, checkpoint = session.compacted_until or vim.NIL,
      prompt = helpers.current_prompt(), effective = helpers.request_messages(),
    })
    return function(refresh)
      if refresh then
        selected_chat = session.chat_id
        snapshot = vim.json.encode({ messages = session.messages, summary = session.context_summary or vim.NIL,
          checkpoint = session.compacted_until or vim.NIL, prompt = helpers.current_prompt(), effective = helpers.request_messages() })
        return true
      end
      if session.busy or session.generation ~= view_generation or session.workspace ~= selected_workspace
        or history.workspace() ~= selected_workspace or session.chat_id ~= selected_chat
        or snapshot ~= vim.json.encode({
          messages = session.messages, summary = session.context_summary or vim.NIL, checkpoint = session.compacted_until or vim.NIL,
          prompt = helpers.current_prompt(), effective = helpers.request_messages(),
        }) then
        return false, 'conversation changed; reopen the editor before saving'
      end
      return true
    end
  end

  function helpers.valid_context(value)
    if type(value) ~= 'table' or not vim.islist(value) or #value == 0 then
      return false, 'context must be a nonempty JSON array of messages'
    end
    local pending = {}
    for i, message in ipairs(value) do
      if type(message) ~= 'table' or not vim.tbl_contains({ 'system', 'user', 'assistant', 'tool' }, message.role)
        or (message.content ~= vim.NIL and type(message.content) ~= 'string' and type(message.content) ~= 'table') then
        return false, 'invalid message at index ' .. i
      end
      if i == 1 and (message.role ~= 'system' or type(message.content) ~= 'string'
        or vim.trim(message.content) == '') then
        return false, 'first message must be a nonempty system prompt'
      end
      if type(message.content) == 'table' then
        if not vim.islist(message.content) then return false, 'invalid content parts at index ' .. i end
        for _, part in ipairs(message.content) do
          if type(part) ~= 'table' or type(part.type) ~= 'string'
            or (part.type == 'text' and type(part.text) ~= 'string') then
            return false, 'invalid content part at index ' .. i
          end
        end
      end
      if message.tool_calls ~= nil and message.tool_calls ~= vim.NIL and message.role ~= 'assistant' then
        return false, 'tool calls require an assistant message at index ' .. i
      end
      if message.tool_calls == vim.NIL then return false, 'tool calls must be an array at index ' .. i end
      if message.role == 'assistant' and message.tool_calls ~= nil then
        if next(pending) then return false, 'missing tool results before message ' .. i end
        if type(message.tool_calls) ~= 'table' or not vim.islist(message.tool_calls) then
          return false, 'invalid tool calls at index ' .. i
        end
        for _, call in ipairs(message.tool_calls) do
          if type(call) ~= 'table' or type(call.id) ~= 'string' or call.id == ''
            or pending[call.id] or type(call['function']) ~= 'table'
            or type(call['function'].name) ~= 'string' or type(call['function'].arguments) ~= 'string' then
            return false, 'invalid or duplicate tool call at index ' .. i
          end
          pending[call.id] = true
        end
      elseif message.role == 'tool' then
        if type(message.tool_call_id) ~= 'string' or not pending[message.tool_call_id] then
          return false, 'tool result without a matching call at index ' .. i
        end
        pending[message.tool_call_id] = nil
      elseif next(pending) then
        return false, 'missing tool results before message ' .. i
      end
    end
    if next(pending) then return false, 'context ends with unfinished tool calls' end
    return true
  end

  function M.context_full()
    helpers.sync_workspace()
    helpers.validate_context_summary()
    local guard = helpers.context_guard()
    local effective = vim.deepcopy(helpers.request_messages())
    if #effective == 0 then effective = { { role = 'system', content = helpers.current_prompt() } } end
    ui.show_context_full(effective, function(edited)
      local ok, err = guard()
      if not ok then return false, err end
      ok, err = helpers.valid_context(edited)
      if not ok then return false, err end
      session.messages = edited
      session.command_results = {}
      session.session_prompt = edited[1].content
      session.context_summary, session.compacted_until, session.context_summary_skills = nil, nil, nil
      session.context_reviews = {}
      session.review_revision = session.review_revision + 1
      session.context_paths, session.selected_skills, session.disabled_context_files = {}, {}, {}
      session.read_versions = {}
      context_files.set_disabled(session.workspace, session.disabled_context_files)
      if not session.chat_id then session.chat_id = history.new_id() end
      helpers.estimate_context()
      helpers.save(true)
      guard(true)
      helpers.render()
      return true
    end)
  end

  function M.system_prompt()
    helpers.sync_workspace()
    local guard = helpers.context_guard()
    ui.show_system_prompt(helpers.current_prompt(), function(edited)
      local ok, err = guard()
      if not ok then return false, err end
      if vim.trim(edited) == '' then return false, 'system prompt cannot be empty' end
      session.session_prompt = edited
      session.review_revision = session.review_revision + 1
      if session.messages[1] then session.messages[1].content = edited end
      if session.chat_id then
        helpers.estimate_context()
        helpers.save()
      end
      guard(true)
      helpers.render()
      return true
    end)
  end

  function M.context_files()
    helpers.sync_workspace()
    local selected_workspace, selected_chat, view_generation = session.workspace, session.chat_id, session.generation
    local function list()
      if session.workspace ~= selected_workspace or history.workspace() ~= selected_workspace then return {} end
      return context_files.entries(session.workspace, approval.workspace_trust(session.workspace), session.context_paths, session.selected_skills)
    end
    context_files_picker.show(session.workspace, list, function(entry)
      if session.busy then return false, 'wait for the current response before changing context files' end
      if session.workspace ~= selected_workspace or history.workspace() ~= selected_workspace
        or session.chat_id ~= selected_chat or session.generation ~= view_generation then
        return false, 'conversation changed; reopen the context files view'
      end
      local current
      for _, item in ipairs(list()) do
        if item.kind == entry.kind and item.path == entry.path then current = item; break end
      end
      if not current or current.included ~= entry.included or current.state ~= entry.state then
        return false, 'available files changed; reopen the context files view'
      end
      if current.kind == 'skill' then
        local next_state = ({ off = 'on', on = 'active', active = 'off' })[current.state]
        for index = #session.selected_skills, 1, -1 do
          if type(session.selected_skills[index]) == 'table' and session.selected_skills[index].name == current.name then
            table.remove(session.selected_skills, index)
          end
        end
        if next_state == 'active' then session.selected_skills[#session.selected_skills + 1] = { name = current.name, path = current.path } end
        session.disabled_context_files[current.path] = next_state == 'off' and true or nil
      else
        session.disabled_context_files[current.path] = current.included and true or nil
      end
      session.review_revision = session.review_revision + 1
      if session.chat_id then
        helpers.estimate_context()
        helpers.save()
        helpers.render()
      end
      return true
    end)
  end

  function M.context()
    helpers.sync_workspace()
    helpers.validate_context_summary()
    local selected_workspace, selected_chat = session.workspace, session.chat_id
    local checkpoint, message_count = session.compacted_until, #session.messages
    local view_generation, original_summary = session.generation, session.context_summary
    local effective = vim.json.encode(helpers.request_messages())
    ui.show_context(helpers.request_messages(), session.context_summary, function(summary)
      if session.busy or session.generation ~= view_generation or session.context_summary ~= original_summary
        or session.workspace ~= selected_workspace or session.chat_id ~= selected_chat
        or session.compacted_until ~= checkpoint or #session.messages ~= message_count
        or effective ~= vim.json.encode(helpers.request_messages()) then
        return false, 'conversation changed; reopen the context view before saving'
      end
      if not checkpoint then return false, 'compact the conversation before editing its summary' end
      if vim.trim(summary) == '' then return false, 'summary cannot be empty' end
      session.context_summary = vim.trim(summary)
      session.review_revision = session.review_revision + 1
      original_summary = session.context_summary
      effective = vim.json.encode(helpers.request_messages())
      helpers.estimate_context()
      helpers.save()
      helpers.render()
      return true
    end)
  end
end

return M
