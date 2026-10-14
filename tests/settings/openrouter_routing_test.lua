vim.opt.runtimepath:prepend(vim.fn.getcwd())
local settings = require('codeit.settings')
local picker = require('codeit.settings.picker')
local base = {
  provider = 'openrouter', models = { openrouter = 'vendor/model', copilot = 'copilot-model', codex = 'codex-model' },
  request_options = { openrouter = { preferred_provider = 'anthropic', service_tier = 'priority', routing_mode = 'price' } },
  model_presets = { reasoning = { options = { routing_mode = 'throughput' } } },
  feature_settings = { tool_review = { options = { routing_mode = 'latency' } } },
}
assert(settings.validate(base))
assert(settings.preset_config(base, 'reasoning').options.routing_mode == 'throughput')
assert(settings.feature_config(base, 'tool_review').options.routing_mode == 'latency')
local inherited = vim.deepcopy(base)
inherited.feature_settings.tool_review.options.routing_mode = nil
assert(settings.feature_config(inherited, 'tool_review').options.routing_mode == 'throughput')
inherited.model_presets.reasoning.options.routing_mode = nil
assert(settings.feature_config(inherited, 'tool_review').options.routing_mode == 'price')
inherited.feature_settings.tool_review.options.routing_mode = ''
assert(settings.feature_config(inherited, 'tool_review').options.routing_mode == '')
inherited.feature_settings.tool_review.provider = 'copilot'
assert(settings.feature_config(inherited, 'tool_review').options.routing_mode == nil)

for _, mode in ipairs(settings.routing_modes) do
  local valid = vim.deepcopy(base)
  valid.request_options.openrouter.routing_mode = mode
  valid.model_presets.reasoning.options.routing_mode = mode
  valid.feature_settings.tool_review.options.routing_mode = mode
  assert(settings.validate(valid))
end
for _, mode in ipairs({ 'invalid', false, 1 }) do
  for _, target in ipairs({ 'main', 'preset', 'feature' }) do
    local invalid = vim.deepcopy(base)
    local options = target == 'main' and invalid.request_options.openrouter
      or (target == 'preset' and invalid.model_presets.reasoning.options or invalid.feature_settings.tool_review.options)
    options.routing_mode = mode
    assert(not settings.validate(invalid), 'invalid routing modes must be rejected at every scope')
  end
end

local steps, applied
require('codeit.settings.menu').select = function(items, _, callback)
  local wanted = table.remove(steps, 1)
  for _, item in ipairs(items) do
    local value = type(item) == 'table' and (item.id or item.value or item.label) or item
    if value == wanted then return callback(item) end
  end
  error('missing menu choice: ' .. tostring(wanted))
end
local function choose(choices, current)
  steps, applied = choices, nil
  picker.show(current or base, function(values, scope)
    assert(scope == 'session')
    applied = values
  end)
  assert(applied and #steps == 0)
  assert(settings.validate(applied))
  return applied
end
for _, mode in ipairs(settings.routing_modes) do
  local result = choose({ 'routing_mode', mode, 'session' })
  assert(result.request_options.openrouter.routing_mode == mode)
  assert(result.request_options.openrouter.preferred_provider == 'anthropic')
  assert(result.request_options.openrouter.service_tier == 'priority')
end
local result = choose({ 'preset_reasoning', 'routing_mode', 'auto', 'back',
  'tool_review', 'routing_mode', 'price', 'back', 'session' })
assert(result.model_presets.reasoning.options.routing_mode == 'auto')
assert(result.feature_settings.tool_review.options.routing_mode == 'price')
result = choose({ 'tool_review', 'routing_mode', '', 'back', 'session' }, result)
assert(settings.feature_config(result, 'tool_review').options.routing_mode == '')
result = choose({ 'tool_review', 'routing_mode', '(inherit)', 'back', 'session' }, result)
assert(result.feature_settings.tool_review.options.routing_mode == nil)
assert(settings.feature_config(result, 'tool_review').options.routing_mode == 'auto')
result = choose({ 'preset_reasoning', 'routing_mode', '(inherit)', 'back', 'session' }, result)
assert(result.model_presets.reasoning.options.routing_mode == nil)
assert(settings.feature_config(result, 'tool_review').options.routing_mode == 'price')
assert(base.request_options.openrouter.routing_mode == 'price')
assert(base.model_presets.reasoning.options.routing_mode == 'throughput')
assert(base.feature_settings.tool_review.options.routing_mode == 'latency', 'picker must not mutate active settings')
print('OpenRouter routing settings: passed')
