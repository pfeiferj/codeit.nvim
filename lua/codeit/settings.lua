local M = {}
M.tiers = { '', 'default', 'flex', 'priority', 'fast', 'ultrafast' }
M.efforts = { '', 'none', 'minimal', 'low', 'medium', 'high', 'xhigh' }
M.copilot_hosts = { '', 'api.githubcopilot.com', 'api.business.githubcopilot.com' }

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
  return true
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
        -- Legacy snapshots predate secondary models; keep the lower-precedence setting.
        local secondary_models = result.secondary_models
        result = vim.deepcopy(saved)
        if result.secondary_models == nil then result.secondary_models = vim.deepcopy(secondary_models or {}) end
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
