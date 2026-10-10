local M = {}
M.tiers = { '', 'default', 'flex', 'priority', 'fast', 'ultrafast' }
M.efforts = { '', 'none', 'minimal', 'low', 'medium', 'high', 'xhigh' }
M.copilot_hosts = { '', 'api.githubcopilot.com', 'api.business.githubcopilot.com' }
M.features = { 'tool_assessment', 'tool_review', 'context_review', 'history_summary', 'compaction' }
M.feature_labels = {
  tool_assessment = 'Tool safety assessments', tool_review = 'Interactive tool reviews',
  context_review = 'Background context review', history_summary = 'History summaries', compaction = 'Compaction',
}
M.option_providers = { preferred_provider = 'openrouter', service_tier = 'openrouter',
  effort = 'openrouter', api_host = 'copilot' }

function M.validate_secondary_models(models)
  if type(models) ~= 'table' then return false, 'invalid secondary models' end
  for provider, model in pairs(models) do
    if not vim.tbl_contains({ 'openrouter', 'copilot' }, provider)
      or type(model) ~= 'string' or model:find('%c')
      or (model ~= '' and vim.trim(model) == '') then
      return false, 'secondary model IDs must be strings keyed by provider (blank = main model)'
    end
  end
  return true
end

function M.validate(settings)
  if type(settings) ~= 'table' or not vim.tbl_contains({ 'openrouter', 'copilot' }, settings.provider)
    or type(settings.models) ~= 'table' then return false, 'invalid provider settings' end
  for _, provider in ipairs({ 'openrouter', 'copilot' }) do
    if type(settings.models[provider]) ~= 'string' or vim.trim(settings.models[provider]) == '' then
      return false, 'model IDs must be nonempty strings'
    end
  end
  if settings.secondary_models ~= nil then
    local ok, err = M.validate_secondary_models(settings.secondary_models)
    if not ok then return false, err end
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
  return true
end

function M.validate_feature_settings(features)
  if type(features) ~= 'table' then return false, 'invalid feature settings' end
  for name, feature in pairs(features) do
    if not vim.tbl_contains(M.features, name) or type(feature) ~= 'table' then
      return false, 'invalid feature: ' .. tostring(name)
    end
    for key, value in pairs(feature) do
      if key == 'provider' then
        if not vim.tbl_contains({ '', 'openrouter', 'copilot' }, value) then return false, 'invalid feature provider' end
      elseif key == 'model' then
        if type(value) ~= 'string' or value:find('%c') or (value ~= '' and vim.trim(value) == '') then
          return false, 'invalid feature model ID'
        end
      elseif key == 'options' then
        if type(value) ~= 'table' then return false, 'invalid feature request options' end
        local options = {}
        for option, setting in pairs(value) do
          local provider = M.option_providers[option]
          if not provider then return false, 'unknown feature request option: ' .. tostring(option) end
          options[provider] = options[provider] or {}
          options[provider][option] = setting
        end
        local ok, err = M.validate({ provider = 'openrouter',
          models = { openrouter = 'validation', copilot = 'validation' }, request_options = options })
        if not ok then return false, err end
      else
        return false, 'unknown feature setting: ' .. tostring(key)
      end
    end
  end
  return true
end

-- Resolve against the selected backend's defaults, never another feature's overrides.
function M.feature_config(settings, name, main_model)
  local feature = (settings.feature_settings or {})[name] or {}
  local provider = feature.provider
  if not provider or provider == '' then provider = settings.provider end
  local model = feature.model
  if not model or model == '' then model = (settings.secondary_models or {})[provider] end
  if not model or model == '' then
    model = provider == settings.provider and main_model or settings.models[provider]
  end
  local options = vim.deepcopy(settings.request_options[provider] or {})
  for key, value in pairs(feature.options or {}) do
    if M.option_providers[key] == provider then options[key] = value end
  end
  return { provider = provider, model = model or settings.models[provider], options = options }
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
        local secondary_models, feature_settings = result.secondary_models, result.feature_settings
        result = vim.deepcopy(saved)
        if result.secondary_models == nil then result.secondary_models = vim.deepcopy(secondary_models or {}) end
        if result.feature_settings == nil then result.feature_settings = vim.deepcopy(feature_settings or {}) end
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
