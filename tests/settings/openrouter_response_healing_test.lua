vim.opt.runtimepath:prepend(vim.fn.getcwd())
local settings = require('codeit.settings')
local picker = require('codeit.settings.picker')
local base = {
  provider = 'openrouter', models = { openrouter = 'vendor/model', copilot = 'copilot-model', codex = 'codex-model' },
  request_options = { openrouter = { routing_mode = 'price', response_healing = true } },
  model_presets = { reasoning = { options = {} } },
  feature_settings = { tool_review = { options = {} } },
}
for _, value in ipairs(settings.response_healing_values) do
  local valid = vim.deepcopy(base)
  valid.request_options.openrouter.response_healing = value
  valid.model_presets.reasoning.options.response_healing = value
  valid.feature_settings.tool_review.options.response_healing = value
  assert(settings.validate(valid))
end
for _, value in ipairs({ 'false', 'true', 0, 1, {} }) do
  for _, target in ipairs({ 'main', 'preset', 'feature' }) do
    local invalid = vim.deepcopy(base)
    local options = target == 'main' and invalid.request_options.openrouter
      or (target == 'preset' and invalid.model_presets.reasoning.options or invalid.feature_settings.tool_review.options)
    options.response_healing = value
    assert(not settings.validate(invalid), 'invalid response healing values must be rejected at every scope')
  end
end
for _, backend in ipairs({ 'copilot', 'codex', 'openai' }) do
  local invalid = vim.deepcopy(base)
  invalid.request_options[backend] = { response_healing = true }
  assert(not settings.validate(invalid), 'response healing is OpenRouter-only')
  local filtered = vim.deepcopy(base)
  filtered.feature_settings.tool_review.provider = backend
  filtered.feature_settings.tool_review.options.response_healing = true
  assert(settings.feature_config(filtered, 'tool_review').options.response_healing == nil)
end
assert(settings.preset_config(base, 'reasoning').options.response_healing == true)
assert(settings.feature_config(base, 'tool_review').options.response_healing == true)
local inherited = vim.deepcopy(base)
inherited.model_presets.reasoning.options.response_healing = false
assert(settings.feature_config(inherited, 'tool_review').options.response_healing == false)
inherited.feature_settings.tool_review.options.response_healing = ''
assert(settings.feature_config(inherited, 'tool_review').options.response_healing == '')
inherited.feature_settings.tool_review.options.response_healing = true
assert(settings.feature_config(inherited, 'tool_review').options.response_healing == true)
assert(vim.json.decode(vim.json.encode(inherited)).model_presets.reasoning.options.response_healing == false)

local steps, applied
require('codeit.settings.menu').select = function(items, opts, callback)
  local wanted = table.remove(steps, 1)
  for _, item in ipairs(items) do
    local value = item
    if type(item) == 'table' then
      value = item.value
      if value == nil then value = item.id or item.label end
      if item.id == 'response_healing' then
        assert(opts.format_item(item):find('JSON response healing:', 1, true))
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
for _, value in ipairs(settings.response_healing_values) do
  local result = choose({ 'response_healing', value, 'session' })
  assert(result.request_options.openrouter.response_healing == value)
  assert(result.request_options.openrouter.routing_mode == 'price')
  for _, target in ipairs({ 'preset_reasoning', 'tool_review' }) do
    result = choose({ target, 'response_healing', value, 'back', 'session' })
    local entry = target == 'tool_review' and result.feature_settings.tool_review or result.model_presets.reasoning
    assert(entry.options.response_healing == value)
    result = choose({ target, 'response_healing', '(inherit)', 'back', 'session' }, result)
    entry = target == 'tool_review' and result.feature_settings.tool_review or result.model_presets.reasoning
    assert(entry.options.response_healing == nil)
    assert(settings.feature_config(result, 'tool_review').options.response_healing == true)
  end
end
assert(base.request_options.openrouter.response_healing == true)
assert(base.model_presets.reasoning.options.response_healing == nil)
assert(base.feature_settings.tool_review.options.response_healing == nil, 'picker must not mutate active settings')
print('OpenRouter response healing settings: passed')
