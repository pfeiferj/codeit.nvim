local M = {}
local tools = require('codeit.tools')
local history = require('codeit.chat.storage')
local settings = require('codeit.settings')

function M.attach(api, session, helpers)
  local M = api
  local defaults = require('codeit.settings.defaults')
  function M.setup(opts)
    session.config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), require('codeit.risk').settings(opts or {}))
    if type(session.config.compaction) ~= 'table' then error('codeit: compaction must be a table') end
    for _, key in ipairs({ 'summary_tokens', 'output_reserve', 'manual_keep_turns' }) do
      local value = session.config.compaction[key]
      if type(value) ~= 'number' or value < (key == 'summary_tokens' and 1 or 0)
        or value >= math.huge or value ~= math.floor(value) then
        error('codeit: compaction.' .. key .. ' must be a ' .. (key == 'summary_tokens' and 'positive' or 'nonnegative') .. ' whole number')
      end
    end
    if type(session.config.context_review_min_tokens) ~= 'number' or session.config.context_review_min_tokens < 0
      or session.config.context_review_min_tokens >= math.huge or session.config.context_review_min_tokens ~= math.floor(session.config.context_review_min_tokens) then
      error('codeit: context_review_min_tokens must be a nonnegative whole number')
    end
    for _, key in ipairs({ 'max_tool_rounds', 'max_subagent_tool_rounds' }) do
      local value = session.config[key]
      if type(value) ~= 'number' or value < 0 or value >= math.huge or value ~= math.floor(value) then
        error('codeit: ' .. key .. ' must be a nonnegative whole number')
      end
    end
    if session.config.max_context_tokens ~= nil and session.config.max_context_tokens ~= false
      and (type(session.config.max_context_tokens) ~= 'number'
      or session.config.max_context_tokens <= 0 or session.config.max_context_tokens == math.huge
      or session.config.max_context_tokens ~= session.config.max_context_tokens) then
      error('codeit: max_context_tokens must be a positive number or false')
    end
    if type(session.config.tool_json_healing) ~= 'boolean' then
      error('codeit: tool_json_healing must be a boolean')
    end
    if type(session.config.context_review) ~= 'boolean' and session.config.context_review ~= 'decisions' then
      error('codeit: context_review must be a boolean or decisions')
    end
    tools.configure(session.config.approval)
    local function receive_background(item, text)
      if not session.busy or not item.origin or not item.origin.turn
        or item.origin.turn ~= session.current_turn or item.origin.chat_id ~= session.chat_id
        or item.origin.workspace ~= session.workspace or session.workspace ~= history.workspace() then
        return false
      end
      table.insert(session.messages, { role = 'user', content = text })
      return true
    end
    local background_tasks = require('codeit.tools.execution.tasks')
    background_tasks.configure(function(task)
      return not session.busy and task.origin and task.origin.chat_id == session.chat_id
        and task.origin.workspace == session.workspace and session.workspace == history.workspace()
    end, function(_, text) M.send(text) end, receive_background)
    local subagents = require('codeit.tools.subagents')
    subagents.configure(function(run)
      return not session.busy and run.origin and run.origin.chat_id == session.chat_id
        and run.origin.workspace == session.workspace and session.workspace == history.workspace()
    end, function(_, text) M.send(text) end, receive_background)
    require('codeit.commands').tasks()
    if not vim.tbl_contains({ 'openrouter', 'copilot', 'codex', 'openai' }, session.config.provider) then
      error('codeit: provider must be openrouter, copilot, codex, or openai')
    end
    local valid, settings_err = settings.validate({ provider = session.config.provider, models = session.config.models,
      feature_settings = session.config.feature_settings, context_review = session.config.context_review,
      approval = { tool_call_risk = session.config.approval.tool_call_risk },
      model_presets = session.config.model_presets, request_options = session.config.request_options })
    if not valid then error('codeit: ' .. settings_err) end
    session.base_settings = { provider = session.config.provider, models = vim.deepcopy(session.config.models),
      context_review = session.config.context_review,
      max_context_tokens = session.config.max_context_tokens == nil and 'auto' or session.config.max_context_tokens,
      model_presets = vim.deepcopy(session.config.model_presets),
      feature_settings = vim.deepcopy(session.config.feature_settings),
      approval = { tool_call_risk = session.config.approval.tool_call_risk },
      request_options = vim.deepcopy(session.config.request_options) }
    helpers.apply_settings(settings.resolve(session.base_settings, history.workspace()))
    M.new()
    require('codeit.commands').register(M)
    require('codeit.log_retention').setup()
  end
end

return M
