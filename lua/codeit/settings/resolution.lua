local M = {}
local definitions = require('codeit.settings.definitions')

function M.feature_preset(settings, name)
  local feature = (settings.feature_settings or {})[name] or {}
  if feature.preset ~= nil then return feature.preset end
  return definitions.feature_presets[name]
end

local function chosen(value)
  return value ~= nil and value ~= ''
end

-- Always start with the resolved backend's main settings, not another preset/feature.
local function resolve_config(settings, preset, feature, main_model)
  local provider = chosen(feature.provider) and feature.provider
    or (chosen(preset.provider) and preset.provider or settings.provider)
  local model = chosen(feature.model) and feature.model or (chosen(preset.model) and preset.model)
  if not model then model = provider == settings.provider and main_model or settings.models[provider] end
  local options = vim.deepcopy(settings.request_options[provider] or {})
  for _, overrides in ipairs({ preset, feature }) do
    for key, value in pairs(overrides.options or {}) do
      if definitions.option_providers[key] == provider or (provider == 'codex' and key == 'effort') then options[key] = value end
    end
  end
  return { provider = provider, model = model or settings.models[provider], options = options }
end

function M.preset_config(settings, name, main_model)
  return resolve_config(settings, (settings.model_presets or {})[name] or {}, {}, main_model)
end

function M.feature_config(settings, name, main_model)
  local feature = (settings.feature_settings or {})[name] or {}
  local preset = (settings.model_presets or {})[M.feature_preset(settings, name)] or {}
  return resolve_config(settings, preset, feature, main_model)
end

return M
