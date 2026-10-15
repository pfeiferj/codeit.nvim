local M = {}
local validation = require('codeit.settings.validation')

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
      local ok, message = validation.validate(saved)
      if ok then
        -- Legacy snapshots keep optional settings from the lower-precedence snapshot.
        local previous = result
        result = { provider = saved.provider, models = vim.tbl_extend('force', {}, previous.models, saved.models),
          max_context_tokens = saved.max_context_tokens,
          request_options = vim.deepcopy(saved.request_options),
          feature_settings = vim.deepcopy(saved.feature_settings), model_presets = vim.deepcopy(saved.model_presets) }
        if result.max_context_tokens == nil then result.max_context_tokens = previous.max_context_tokens end
        for _, key in ipairs({ 'feature_settings', 'model_presets' }) do
          if result[key] == nil then result[key] = vim.deepcopy(previous[key] or {}) end
        end
      else vim.notify('codeit: ignoring saved settings: ' .. message, vim.log.levels.WARN) end
    end
  end
  return result
end

function M.save(settings, scope, workspace)
  local ok, err = validation.validate(settings)
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
