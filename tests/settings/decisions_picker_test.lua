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
assert(contains(false) and contains(true) and contains('decisions') and contains('disabled'))
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
local http = require('codeit.providers.http')
local original_get, original_key = http.get, vim.env.OPENROUTER_API_KEY
vim.env.OPENROUTER_API_KEY = 'test-openrouter-key'
local urls = {}
http.get = function(url, _, callback)
  urls[#urls + 1] = url
  callback({ data = { { id = 'typesafe/jev-1.13' } } })
end
local picker = require('codeit.settings.picker')
local router = vim.deepcopy(require('codeit.settings.defaults'))
router.provider = 'openrouter'
router.request_options.openrouter = { effort = 'low' }
router.approval = { tool_call_risk = 'decisions' }
router.feature_settings.tool_assessment = { provider = 'openrouter' }
picker.show(router, function(values) applied = values end)
choose('tool_assessment')
choose('model')
assert(urls[#urls] == 'https://openrouter.ai/api/v1/models?output_modalities=decisions',
  'decisions model browsing must request the decisions output modality')
choose('typesafe/jev-1.13')
choose('back')
choose('model')
assert(urls[#urls] == 'https://openrouter.ai/api/v1/models', 'main model browsing must remain unfiltered')
pending.callback(nil)
choose('preset_fast')
choose('model')
assert(urls[#urls] == 'https://openrouter.ai/api/v1/models', 'chat preset browsing must remain unfiltered')
pending.callback(nil)
choose('back')
choose('tool_call_risk')
choose(false)
choose('tool_assessment')
choose('model')
assert(urls[#urls] == 'https://openrouter.ai/api/v1/models',
  'chat-based tool assessment model browsing must remain unfiltered')
pending.callback(nil)
choose('back')
choose('session')
assert(settings.validate(applied))
assert(applied.feature_settings.tool_assessment.model == 'typesafe/jev-1.13')
assert(applied.request_options.openrouter.output_modalities == nil)
assert(applied.feature_settings.tool_assessment.options.output_modalities == nil,
  'the catalog filter must not be persisted as a completion option')
assert(router.feature_settings.tool_assessment.model == nil, 'browsing must not mutate the original settings')
picker.show(router, function(values) applied = values end)
choose('context_review_mode')
assert(contains(false) and contains(true) and contains('decisions'))
choose('decisions')
choose('context_review')
assert(not contains('preset'))
choose('provider')
assert(contains('typesafe') and contains('decisions') and contains('openrouter') and not contains('copilot'))
choose('openrouter')
choose('model')
assert(urls[#urls] == 'https://openrouter.ai/api/v1/models?output_modalities=decisions')
choose('typesafe/jev-1.13')
choose('back')
choose('workspace')
assert(settings.validate(applied) and applied.context_review == 'decisions')
assert(settings.feature_config(applied, 'context_review').model == 'typesafe/jev-1.13')
assert(applied.approval.tool_call_risk == 'decisions', 'context mode must not change risk mode')
picker.show(current, function(values) applied = values end)
choose('tool_call_risk')
assert(pending.opts.format_item('disabled') == 'Disabled (chat model supplies summary only)')
assert(pending.opts.format_item(false) == 'Separate automatic assessment (default)')
choose('disabled')
choose('session')
assert(settings.validate(applied) and applied.approval.tool_call_risk == 'disabled')
assert(current.approval.tool_call_risk == false, 'picker must not mutate the original settings')
http.get, vim.env.OPENROUTER_API_KEY = original_get, original_key
print('decisions settings picker tests passed')
