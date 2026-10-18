vim.opt.runtimepath:prepend(vim.fn.getcwd())
local pending
package.loaded['codeit.settings.menu'] = { select = function(items, opts, callback)
  pending = { items = items, opts = opts, callback = callback }
end }
local function choose(id)
  for _, item in ipairs(pending.items) do
    if type(item) == 'table' and item.id == id or item == id then return pending.callback(item) end
  end
  error('missing menu choice: ' .. tostring(id))
end
local function contains(id)
  for _, item in ipairs(pending.items) do
    if type(item) == 'table' and item.id == id or item == id then return true end
  end
  return false
end
local text_value
require('codeit.ui.input').show = function(_, callback) callback(text_value) end
local settings = require('codeit.settings')
local current = vim.deepcopy(require('codeit.settings.defaults'))
current.approval = { tool_call_risk = false }
local applied, scope
require('codeit.settings.picker').show(current, function(values, selected_scope) applied, scope = values, selected_scope end)
choose('tool_call_risk')
assert(contains(false) and contains(true) and contains('decisions'))
choose('decisions')
choose('tool_assessment')
assert(not contains('preset'), 'decisions mode must not offer ignored chat presets')
choose('provider')
assert(contains('typesafe') and contains('openrouter') and contains('decisions') and not contains('copilot'))
choose('decisions')
assert(contains('base_url') and contains('api_key_env'))
text_value = 'http://localhost:8080/v1'
choose('base_url')
text_value = ''
choose('api_key_env')
text_value = 'local-jev'
choose('manual')
choose('back')
choose('session')
assert(applied and scope == 'session' and settings.validate(applied))
assert(applied.approval.tool_call_risk == 'decisions')
local config = settings.feature_config(applied, 'tool_assessment')
assert(config.provider == 'decisions' and config.model == 'local-jev')
assert(config.options.base_url == 'http://localhost:8080/v1' and config.options.api_key_env == '')
assert(current.approval.tool_call_risk == false and current.feature_settings.tool_assessment == nil)
print('decisions settings picker tests passed')
