vim.opt.runtimepath:prepend(vim.fn.getcwd())
local settings = require('codeit.settings')
local values = vim.deepcopy(require('codeit.settings.defaults'))
values.approval = { tool_call_risk = false }
values.context_review = 'decisions'
values.model_presets.long_context = { provider = 'copilot', model = 'chat-only' }
assert(settings.validate(values))
local config = settings.feature_config(values, 'context_review')
assert(config.provider == 'typesafe' and config.model == 'jev-latest')
assert(settings.feature_config(values, 'tool_assessment').provider == 'openrouter', 'risk mode is independent')
values.feature_settings.context_review = { provider = '' }
assert(settings.feature_config(values, 'context_review').provider == 'typesafe')
values.feature_settings.context_review = { provider = 'openrouter' }
config = settings.feature_config(values, 'context_review')
assert(config.provider == 'openrouter' and config.model == 'typesafe/jev-1.13')
values.feature_settings.context_review = { provider = 'copilot' }
assert(not settings.validate(values))
values.feature_settings.context_review = { provider = 'decisions', model = 'local',
  options = { base_url = 'http://localhost:8080/v1', api_key_env = '' } }
assert(settings.validate(values))
config = settings.feature_config(values, 'context_review')
assert(config.provider == 'decisions' and config.model == 'local' and config.options.api_key_env == '')
local workspace = vim.fn.tempname()
assert(settings.save(values, 'workspace', workspace))
local restored = settings.resolve(vim.tbl_extend('force', {}, values, { context_review = false }), workspace)
assert(restored.context_review == 'decisions')
assert(vim.deep_equal(settings.feature_config(restored, 'context_review'), config))
values.context_review = false
assert(settings.validate(values), 'disabled reviews may retain their unused decisions configuration')
for _, mode in ipairs({ true, 'invalid' }) do
  values.context_review = mode
  assert(not settings.validate(values))
end
values.feature_settings.context_review = nil
values.context_review = true
assert(settings.validate(values))
config = settings.feature_config(values, 'context_review')
assert(config.provider == 'copilot' and config.model == 'chat-only')
values.context_review = false
assert(settings.save(values, 'workspace', workspace))
assert(settings.resolve(vim.tbl_extend('force', {}, values, { context_review = 'decisions' }), workspace).context_review == false)
values.context_review = nil
assert(settings.save(values, 'workspace', workspace))
assert(settings.resolve(vim.tbl_extend('force', {}, values, { context_review = 'decisions' }), workspace).context_review == 'decisions',
  'older saved settings must inherit the setup context-review mode')
print('context decisions settings tests passed')
