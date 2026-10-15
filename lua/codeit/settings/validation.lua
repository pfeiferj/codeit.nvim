local M = {}
local definitions = require('codeit.settings.definitions')

function M.validate(settings)
  if type(settings) ~= 'table' or not vim.tbl_contains({ 'openrouter', 'copilot', 'codex', 'openai' }, settings.provider)
    or type(settings.models) ~= 'table' then return false, 'invalid provider settings' end
  for _, provider in ipairs({ 'openrouter', 'copilot', 'codex', 'openai' }) do
    local value = settings.models[provider]
    -- Older snapshots may lack models for newly added backends.
    if ((provider ~= 'codex' and provider ~= 'openai') or value ~= nil or settings.provider == provider)
      and (type(value) ~= 'string' or vim.trim(value) == '') then
      return false, 'model IDs must be nonempty strings'
    end
  end

  local options = settings.request_options
  if type(options) ~= 'table' then return false, 'invalid request options' end
  for provider, values in pairs(options) do
    if not vim.tbl_contains({ 'openrouter', 'copilot', 'codex', 'openai' }, provider) or type(values) ~= 'table' then
      return false, 'invalid provider request options'
    end
    for key, value in pairs(values) do
      if provider == 'openai' then
        if key == 'base_url' then
          local url, err = require('codeit.providers.openai').url(values)
          if not url then return false, err end
        elseif key == 'api_key_env' then
          if type(value) ~= 'string' or (value ~= '' and not value:match('^[%a_][%w_]*$')) then
            return false, 'invalid API key environment variable'
          end
        else
          return false, 'unknown OpenAI-compatible request option: ' .. tostring(key)
        end
      elseif provider == 'copilot' then
        if key == 'api_host' then
          if not vim.tbl_contains(definitions.copilot_hosts, value) then return false, 'invalid Copilot API host' end
        elseif key == 'effort' then
          if not vim.tbl_contains(definitions.efforts, value) then return false, 'invalid effort' end
        else
          return false, 'unknown Copilot request option: ' .. tostring(key)
        end
      elseif provider == 'codex' then
        if key ~= 'effort' then return false, 'unknown Codex request option: ' .. tostring(key) end
        if not vim.tbl_contains(definitions.efforts, value) then return false, 'invalid effort' end
      elseif key == 'preferred_provider' then
        if type(value) ~= 'string' or value:find('%c') then return false, 'invalid preferred provider slug' end
      elseif key == 'routing_mode' then
        if not vim.tbl_contains(definitions.routing_modes, value) then return false, 'invalid routing mode' end
      elseif key == 'allow_fallbacks' then
        if not vim.tbl_contains(definitions.fallback_values, value) then return false, 'invalid provider fallback setting' end
      elseif key == 'service_tier' then
        if not vim.tbl_contains(definitions.tiers, value) then return false, 'invalid service tier' end
      elseif key == 'effort' then
        if not vim.tbl_contains(definitions.efforts, value) then return false, 'invalid effort' end
      else
        return false, 'unknown request option: ' .. tostring(key)
      end
    end
  end
  if settings.feature_settings ~= nil then
    local ok, err = M.validate_feature_settings(settings.feature_settings)
    if not ok then return false, err end
  end
  if settings.model_presets ~= nil then
    local ok, err = M.validate_model_presets(settings.model_presets)
    if not ok then return false, err end
  end
  return true
end

local function validate_overrides(entries, names, label, allow_preset)
  if type(entries) ~= 'table' then return false, 'invalid ' .. label .. ' settings' end
  for name, entry in pairs(entries) do
    if not vim.tbl_contains(names, name) or type(entry) ~= 'table' then
      return false, 'invalid ' .. label .. ': ' .. tostring(name)
    end
    for key, value in pairs(entry) do
      if key == 'preset' and allow_preset then
        if value ~= '' and not vim.tbl_contains(definitions.presets, value) then return false, 'invalid feature preset' end
      elseif key == 'provider' then
        if not vim.tbl_contains({ '', 'openrouter', 'copilot', 'codex', 'openai' }, value) then return false, 'invalid ' .. label .. ' provider' end
      elseif key == 'model' then
        if type(value) ~= 'string' or value:find('%c') or (value ~= '' and vim.trim(value) == '') then
          return false, 'invalid ' .. label .. ' model ID'
        end
      elseif key == 'options' then
        if type(value) ~= 'table' then return false, 'invalid ' .. label .. ' request options' end
        local options = {}
        for option, setting in pairs(value) do
          local provider = definitions.option_providers[option]
          if not provider then return false, 'unknown ' .. label .. ' request option: ' .. tostring(option) end
          options[provider] = options[provider] or {}
          options[provider][option] = setting
        end
        local ok, err = M.validate({ provider = 'openrouter',
          models = { openrouter = 'validation', copilot = 'validation' }, request_options = options })
        if not ok then return false, err end
      else
        return false, 'unknown ' .. label .. ' setting: ' .. tostring(key)
      end
    end
  end
  return true
end

function M.validate_feature_settings(features)
  return validate_overrides(features, definitions.features, 'feature', true)
end

function M.validate_model_presets(presets)
  return validate_overrides(presets, definitions.presets, 'preset', false)
end

return M
