local M = {}
M.tiers = { '', 'default', 'flex', 'priority', 'fast', 'ultrafast' }
M.efforts = { '', 'none', 'minimal', 'low', 'medium', 'high', 'xhigh' }
M.copilot_hosts = { '', 'api.githubcopilot.com', 'api.business.githubcopilot.com' }
M.features = { 'tool_assessment', 'tool_review', 'context_review', 'history_summary', 'compaction', 'cost_review' }
M.presets = { 'fast', 'long_context', 'reasoning' }
M.preset_labels = { fast = 'fast', long_context = 'long context', reasoning = 'reasoning' }
M.feature_presets = {
  tool_assessment = 'fast', tool_review = 'reasoning', context_review = 'long_context',
  history_summary = 'fast', compaction = 'long_context', cost_review = 'fast',
}
M.feature_labels = {
  tool_assessment = 'Tool safety assessments', tool_review = 'Interactive tool reviews',
  context_review = 'Background context review', history_summary = 'History summaries', compaction = 'Compaction',
  cost_review = 'Cost review chat',
}
M.option_providers = { preferred_provider = 'openrouter', service_tier = 'openrouter',
  effort = 'openrouter', api_host = 'copilot' }

function M.validate(settings)
  if type(settings) ~= 'table' or not vim.tbl_contains({ 'openrouter', 'copilot' }, settings.provider)
    or type(settings.models) ~= 'table' then return false, 'invalid provider settings' end
  for _, provider in ipairs({ 'openrouter', 'copilot' }) do
    if type(settings.models[provider]) ~= 'string' or vim.trim(settings.models[provider]) == '' then
      return false, 'model IDs must be nonempty strings'
    end
  end

  local options = settings.request_options
  if type(options) ~= 'table' then return false, 'invalid request options' end
  for provider, values in pairs(options) do
    if not vim.tbl_contains({ 'openrouter', 'copilot' }, provider) or type(values) ~= 'table' then
      return false, 'invalid provider request options'
    end
    for key, value in pairs(values) do
      if provider == 'copilot' then
        if key ~= 'api_host' then return false, 'unknown Copilot request option: ' .. tostring(key) end
        if not vim.tbl_contains(M.copilot_hosts, value) then return false, 'invalid Copilot API host' end
      elseif key == 'preferred_provider' then
        if type(value) ~= 'string' or value:find('%c') then return false, 'invalid preferred provider slug' end
      elseif key == 'service_tier' then
        if not vim.tbl_contains(M.tiers, value) then return false, 'invalid service tier' end
      elseif key == 'effort' then
        if not vim.tbl_contains(M.efforts, value) then return false, 'invalid effort' end
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
        if value ~= '' and not vim.tbl_contains(M.presets, value) then return false, 'invalid feature preset' end
      elseif key == 'provider' then
        if not vim.tbl_contains({ '', 'openrouter', 'copilot' }, value) then return false, 'invalid ' .. label .. ' provider' end
      elseif key == 'model' then
        if type(value) ~= 'string' or value:find('%c') or (value ~= '' and vim.trim(value) == '') then
          return false, 'invalid ' .. label .. ' model ID'
        end
      elseif key == 'options' then
        if type(value) ~= 'table' then return false, 'invalid ' .. label .. ' request options' end
        local options = {}
        for option, setting in pairs(value) do
          local provider = M.option_providers[option]
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
  return validate_overrides(features, M.features, 'feature', true)
end

function M.validate_model_presets(presets)
  return validate_overrides(presets, M.presets, 'preset', false)
end

function M.feature_preset(settings, name)
  local feature = (settings.feature_settings or {})[name] or {}
  if feature.preset ~= nil then return feature.preset end
  return M.feature_presets[name]
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
      if M.option_providers[key] == provider then options[key] = value end
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

local function filename()
  return vim.fn.stdpath('data') .. '/codeit/settings.json'
end

local function read()
  local file = io.open(filename(), 'r')
  if not file then return { workspaces = {} } end
  local text = file:read('*a')
  file:close()
  local ok, data = pcall(vim.json.decode, text)
  if not ok or type(data) ~= 'table' or type(data.workspaces) ~= 'table' then
    return nil, 'invalid settings file'
  end
  return data
end

function M.resolve(base, workspace)
  local data, err = read()
  if not data then
    vim.notify('codeit: ' .. err, vim.log.levels.WARN)
    return vim.deepcopy(base)
  end
  local result = vim.deepcopy(base)
  for _, saved in ipairs({ data.global or {}, data.workspaces[workspace] or {} }) do
    if type(saved) ~= 'table' or next(saved) then
      local ok, message = M.validate(saved)
      if ok then
        -- Legacy snapshots keep optional settings from the lower-precedence snapshot.
        local previous = result
        result = { provider = saved.provider, models = vim.deepcopy(saved.models),
          request_options = vim.deepcopy(saved.request_options),
          feature_settings = vim.deepcopy(saved.feature_settings), model_presets = vim.deepcopy(saved.model_presets) }
        for _, key in ipairs({ 'feature_settings', 'model_presets' }) do
          if result[key] == nil then result[key] = vim.deepcopy(previous[key] or {}) end
        end
      else vim.notify('codeit: ignoring saved settings: ' .. message, vim.log.levels.WARN) end
    end
  end
  return result
end

function M.save(settings, scope, workspace)
  local ok, err = M.validate(settings)
  if not ok then return false, err end
  if scope ~= 'global' and scope ~= 'workspace' then return false, 'invalid settings scope' end
  if scope == 'workspace' and (type(workspace) ~= 'string' or workspace == '') then
    return false, 'invalid workspace'
  end
  local data
  data, err = read()
  if not data then return false, err end
  if scope == 'global' then data.global = vim.deepcopy(settings)
  else data.workspaces[workspace] = vim.deepcopy(settings) end
  local path = filename()
  local dir = vim.fn.fnamemodify(path, ':h')
  vim.fn.mkdir(dir, 'p')
  local temporary = path .. '.' .. tostring(vim.uv.hrtime()) .. '.tmp'
  local fd
  fd, err = vim.uv.fs_open(temporary, 'w', 384)
  if not fd then return false, err end
  local encoded = vim.json.encode(data)
  local written
  written, err = vim.uv.fs_write(fd, encoded, 0)
  vim.uv.fs_close(fd)
  if written ~= #encoded then vim.uv.fs_unlink(temporary); return false, err or 'incomplete settings write' end
  ok, err = vim.uv.fs_rename(temporary, path)
  if not ok then vim.uv.fs_unlink(temporary) end
  return ok, err
end

return M
