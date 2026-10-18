local M = {}
local history = require('codeit.chat.storage')
local settings = require('codeit.settings')
local settings_picker = require('codeit.settings.picker')

function M.attach(api, session, helpers)
  local M = api
  function M.get_settings()
    helpers.sync_workspace()
    local values = { provider = session.config.provider, models = vim.deepcopy(session.config.models),
      max_context_tokens = session.config.max_context_tokens == nil and 'auto' or session.config.max_context_tokens,
      model_presets = vim.deepcopy(session.config.model_presets),
      feature_settings = vim.deepcopy(session.config.feature_settings),
      approval = { tool_call_risk = session.config.approval.tool_call_risk },
      request_options = vim.deepcopy(session.config.request_options) }
    values.models[session.config.provider] = helpers.model()
    return values
  end

  function M.configure(values, scope)
    helpers.sync_workspace()
    if session.busy then return false, 'wait for the current response before changing settings' end
    values = require('codeit.risk').settings(values)
    local ok, err = settings.validate(values)
    if not ok then return false, err end
    values = vim.deepcopy(values)
    if values.max_context_tokens == nil then
      values.max_context_tokens = session.config.max_context_tokens == nil and 'auto' or session.config.max_context_tokens
    end
    values.approval = values.approval or {}
    if values.approval.tool_call_risk == nil then
      values.approval.tool_call_risk = session.config.approval.tool_call_risk
    end
    if values.model_presets == nil then values.model_presets = vim.deepcopy(session.config.model_presets) end
    if values.feature_settings == nil then values.feature_settings = vim.deepcopy(session.config.feature_settings) end
    scope = scope or 'session'
    if not vim.tbl_contains({ 'session', 'global', 'workspace' }, scope) then return false, 'invalid settings scope' end
    if scope ~= 'session' then
      ok, err = settings.save(values, scope, session.workspace)
      if not ok then return false, err end
    end
    local changed = values.provider ~= session.config.provider or values.models[values.provider] ~= helpers.model()
    if changed then M.new() end
    helpers.apply_settings(values)
    helpers.save()
    helpers.render()
    return true
  end

  function M.settings()
    helpers.sync_workspace()
    if session.busy then
      vim.notify('codeit: wait for the current response before changing settings', vim.log.levels.WARN)
      return
    end
    local selected_workspace, view_generation = session.workspace, session.generation
    settings_picker.show(M.get_settings(), function(values, scope)
      local ok, err = M.configure(values, scope)
      if not ok then vim.notify('codeit: ' .. tostring(err), vim.log.levels.ERROR)
      else vim.notify('codeit: settings applied (' .. scope .. ')') end
    end, function()
      return not session.busy and session.generation == view_generation and history.workspace() == selected_workspace
    end)
  end
end

return M
