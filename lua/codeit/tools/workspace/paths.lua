local M = {}

function M.root()
  return vim.uv.fs_realpath(vim.fn.getcwd())
end

function M.within(path, base)
  return path == base or path:sub(1, #base + 1) == base .. '/'
end

function M.resolve(path, must_exist, trusted_read)
  if type(path) ~= 'string' or path == '' or path:find('\0', 1, true) then return nil, 'Invalid path' end
  local base = M.root()
  if not base then return nil, 'Workspace does not exist' end
  local absolute = vim.fn.fnamemodify(path:sub(1, 1) == '/' and path or base .. '/' .. path, ':p'):gsub('/+$', '')
  local real = vim.uv.fs_realpath(absolute)
  local trusted = trusted_read and real
    and require('codeit.tools.approval').workspace_trust(vim.fn.fnamemodify(real, ':h'))
  if not trusted and (not M.within(absolute, base) or absolute == base) then return nil, 'Path is outside the workspace' end
  if real then
    if not trusted and not M.within(real, base) then return nil, 'Path resolves outside the workspace' end
    if not vim.uv.fs_stat(real) or vim.uv.fs_stat(real).type ~= 'file' then return nil, 'Not a regular file' end
    return absolute
  end
  if must_exist then return nil, 'File does not exist' end
  local parent = vim.uv.fs_realpath(vim.fn.fnamemodify(absolute, ':h'))
  if not parent or not M.within(parent, base) then return nil, 'Parent directory is outside the workspace or does not exist' end
  if vim.uv.fs_lstat(absolute) then return nil, 'Path already exists' end
  return absolute
end

function M.directory(path, base)
  if path == nil or path == '' or path == '.' then return base end
  if type(path) ~= 'string' or path:find('\0', 1, true) then return nil, 'Invalid directory' end
  local absolute = vim.fs.normalize(path:sub(1, 1) == '/' and path or base .. '/' .. path)
  local real = vim.uv.fs_realpath(absolute)
  if not M.within(absolute, base) or not real or not M.within(real, base) then return nil, 'Directory is outside the workspace or does not exist' end
  if vim.uv.fs_stat(real).type ~= 'directory' then return nil, 'Not a directory' end
  return absolute
end

function M.scope(path, base)
  return path == base and '.' or './' .. path:sub(#base + 2)
end

function M.integer(value, minimum)
  return type(value) == 'number' and value < math.huge and value % 1 == 0 and value >= minimum
end

return M
