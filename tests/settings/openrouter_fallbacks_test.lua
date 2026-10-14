vim.opt.runtimepath:prepend(vim.fn.getcwd())
local settings = require('codeit.settings')
local picker = require('codeit.settings.picker')
local base = {
  provider = 'openrouter', models = { openrouter = 'vendor/model', copilot = 'copilot-model', codex = 'codex-model' },
  request_options = { openrouter = { routing_mode = 'price', allow_fallbacks = false } },
  model_presets = { reasoning = { options = {} } },
  feature_settings = { tool_review = { options = {} } },
}
for _, value in ipairs(settings.fallback_values) do
  local valid = vim.deepcopy(base)
  valid.request_options.openrouter.allow_fallbacks = value
  valid.model_presets.reasoning.options.allow_fallbacks = value
  valid.feature_settings.tool_review.options.allow_fallbacks = value
  assert(settings.validate(valid))
end
for _, value in ipairs({ 'false', 'true', 0, 1, {} }) do
  for _, target in ipairs({ 'main', 'preset', 'feature' }) do
    local invalid = vim.deepcopy(base)
    local options = target == 'main' and invalid.request_options.openrouter
      or (target == 'preset' and invalid.model_presets.reasoning.options or invalid.feature_settings.tool_review.options)
    options.allow_fallbacks = value
    assert(not settings.validate(invalid), 'invalid fallback values must be rejected at every scope')
  end
end
for _, backend in ipairs({ 'copilot', 'codex' }) do
  local invalid = vim.deepcopy(base)
  invalid.request_options[backend] = { allow_fallbacks = false }
  assert(not settings.validate(invalid), 'fallbacks are OpenRouter-only')
  local filtered = vim.deepcopy(base)
  filtered.feature_settings.tool_review.provider = backend
  filtered.feature_settings.tool_review.options.allow_fallbacks = false
  assert(settings.feature_config(filtered, 'tool_review').options.allow_fallbacks == nil)
end
assert(settings.preset_config(base, 'reasoning').options.allow_fallbacks == false)
assert(settings.feature_config(base, 'tool_review').options.allow_fallbacks == false)
local inherited = vim.deepcopy(base)
inherited.model_presets.reasoning.options.allow_fallbacks = true
assert(settings.feature_config(inherited, 'tool_review').options.allow_fallbacks == true)
inherited.feature_settings.tool_review.options.allow_fallbacks = false
assert(settings.feature_config(inherited, 'tool_review').options.allow_fallbacks == false)
inherited.feature_settings.tool_review.options.allow_fallbacks = ''
assert(settings.feature_config(inherited, 'tool_review').options.allow_fallbacks == '')
inherited.feature_settings.tool_review.options.allow_fallbacks = nil
assert(settings.feature_config(inherited, 'tool_review').options.allow_fallbacks == true)
assert(vim.json.decode(vim.json.encode(base)).request_options.openrouter.allow_fallbacks == false)

local steps, applied
require('codeit.settings.menu').select = function(items, opts, callback)
  local wanted = table.remove(steps, 1)
  for _, item in ipairs(items) do
    local value = item
    if type(item) == 'table' then
      value = item.value
      if value == nil then value = item.id or item.label end
      if item.id == 'allow_fallbacks' then
        assert(opts.format_item(item):find('Provider fallback:', 1, true))
        assert(item.section == 'Request options' or item.section == 'Main chat request options')
      end
    end
    if value == wanted then
      if wanted == false then assert(opts.format_item(item) == 'Disabled') end
      return callback(item)
    end
  end
  error('missing menu choice: ' .. tostring(wanted))
end
local function choose(choices, current)
  steps, applied = choices, nil
  picker.show(current or base, function(values, scope)
    assert(scope == 'session')
    applied = values
  end)
  assert(applied and #steps == 0 and settings.validate(applied))
  return applied
end
for _, value in ipairs(settings.fallback_values) do
  local result = choose({ 'allow_fallbacks', value, 'session' })
  assert(result.request_options.openrouter.allow_fallbacks == value)
  assert(result.request_options.openrouter.routing_mode == 'price')
  for _, target in ipairs({ 'preset_reasoning', 'tool_review' }) do
    result = choose({ target, 'allow_fallbacks', value, 'back', 'session' })
    local entry = target == 'tool_review' and result.feature_settings.tool_review or result.model_presets.reasoning
    assert(entry.options.allow_fallbacks == value)
    result = choose({ target, 'allow_fallbacks', '(inherit)', 'back', 'session' }, result)
    entry = target == 'tool_review' and result.feature_settings.tool_review or result.model_presets.reasoning
    assert(entry.options.allow_fallbacks == nil)
    assert(settings.feature_config(result, 'tool_review').options.allow_fallbacks == false)
  end
end
assert(base.request_options.openrouter.allow_fallbacks == false)
assert(base.model_presets.reasoning.options.allow_fallbacks == nil)
assert(base.feature_settings.tool_review.options.allow_fallbacks == nil, 'picker must not mutate active settings')
print('OpenRouter fallback settings: passed')
