vim.opt.runtimepath:prepend(vim.fn.getcwd())
local settings = require('codeit.settings')
local defaults = require('codeit.settings.defaults')
local values = vim.deepcopy(defaults)
-- Persisted settings exclude setup-only approval options.
values.approval = { tool_call_safety = 'decisions' }
assert(settings.validate(values))
local config = settings.feature_config(values, 'tool_assessment')
assert(config.provider == 'typesafe' and config.model == 'jev-latest')
values.feature_settings.tool_assessment = { provider = '' }
assert(settings.feature_config(values, 'tool_assessment').provider == 'typesafe')
values.feature_settings.tool_assessment = { provider = 'copilot' }
assert(not settings.validate(values), 'chat-only providers cannot perform decisions assessments')
values.feature_settings.tool_assessment = nil
values.models.typesafe = 123
assert(not settings.validate(values))
values.models.typesafe = 'jev-latest'
values.model_presets.fast = { provider = 'copilot', model = 'chat-only-model' }
config = settings.feature_config(values, 'tool_assessment')
assert(config.provider == 'typesafe' and config.model == 'jev-latest', 'chat presets must not leak into decisions requests')
values.feature_settings.tool_assessment = { provider = 'openrouter' }
config = settings.feature_config(values, 'tool_assessment')
assert(config.provider == 'openrouter' and config.model == 'typesafe/jev-1.13')
values.feature_settings.tool_assessment = { provider = 'decisions', model = 'local', options = {
  base_url = 'http://localhost:8080/v1', api_key_env = '',
} }
values.request_options.decisions = { base_url = 'http://localhost:9999/v1', api_key_env = 'LOCAL_KEY' }
assert(settings.validate(values))
config = settings.feature_config(values, 'tool_assessment')
assert(config.provider == 'decisions' and config.model == 'local')
assert(config.options.base_url == 'http://localhost:8080/v1' and config.options.api_key_env == '')
local workspace = vim.fn.tempname()
assert(settings.save(values, 'workspace', workspace))
local saved = settings.resolve(vim.tbl_extend('force', values, { approval = { tool_call_safety = false } }), workspace)
assert(saved.approval.tool_call_safety == 'decisions')
assert(vim.deep_equal(settings.feature_config(saved, 'tool_assessment'), config))
values.feature_settings.tool_assessment = { provider = 'typesafe', options = { api_key_env = 'CUSTOM_TYPESAFE_KEY' } }
assert(settings.validate(values))
assert(settings.feature_config(values, 'tool_assessment').options.api_key_env == 'CUSTOM_TYPESAFE_KEY')
values.feature_settings.tool_review = { provider = 'typesafe' }
assert(not settings.validate(values), 'decisions-only provider cannot be used for text reviews')
values.feature_settings.tool_review = nil
values.request_options.decisions.api_key_env = 'bad-name'
assert(not settings.validate(values))
values.request_options.decisions.api_key_env = ''
values.request_options.decisions.base_url = 'file:///tmp'
assert(not settings.validate(values))
values.request_options.decisions = nil
values.approval.tool_call_safety = false
assert(not settings.validate(values), 'decisions-only providers cannot generate text in the legacy mode')
values.feature_settings.tool_assessment = nil
config = settings.feature_config(values, 'tool_assessment')
assert(config.provider == 'copilot' and config.model == 'chat-only-model', 'legacy assessment resolution is unchanged')

local decisions = require('codeit.tools.approval.decisions')
local questions = decisions.questions(true)
assert(questions.safety_score.type == 'score' and #questions.safety_score.criteria == 10)
assert(questions.is_write and questions.rule_compliant and not questions.summary)
local function answers(score, write, compliant)
  return { safety_score = { type = 'score', score = score },
    is_write = { type = 'choice', choice = write or 'false' },
    rule_compliant = { type = 'choice', choice = compliant or 'true' } }
end
assert(decisions.parse(answers(0), true).safety_score == 1)
assert(decisions.parse(answers(9), true).safety_score == 10)
assert(decisions.parse(answers(4.01), true).safety_score == 6, 'fractional scores round up')
assert(decisions.parse(answers(0, 'true'), true).is_write == true)
assert(decisions.parse(answers(0, 'false', 'false'), true).rule_compliant == false)
for _, score in ipairs({ -1, 10, '0', math.huge, 0/0 }) do assert(not decisions.parse(answers(score), true)) end
assert(not decisions.parse(answers(0, 'unknown'), true))
assert(not decisions.parse(answers(0, 'false', 'unknown'), true))
local partial = answers(0)
partial.rule_compliant = nil
assert(not decisions.parse(partial, true))
assert(decisions.parse(partial, false))
print('decisions settings and parsing tests passed')
