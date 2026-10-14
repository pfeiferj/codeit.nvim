local M = {}

local function filename()
  return vim.fn.stdpath('data') .. '/codeit/seen_workspaces.json'
end

local function is_temporary(workspace)
  -- Neovim tempname() paths, including descendants and paths from past sessions.
  local suffix = workspace:match('/nvim%.[^/]+/[^/]+/%d+(.*)$')
  return suffix ~= nil and (suffix == '' or suffix:sub(1, 1) == '/')
end

local function load()
  local file = io.open(filename(), 'r')
  if not file then return {} end
  local text = file:read('*a')
  file:close()
  local ok, data = pcall(vim.json.decode, text)
  local paths = {}
  if ok and type(data) == 'table' then
    for path, seen in pairs(data) do
      if type(path) == 'string' and path:sub(1, 1) == '/' and not path:find('\0', 1, true) and seen == true then
        paths[path] = true
      end
    end
  end
  return paths
end

function M.record(workspace)
  if is_temporary(workspace) then return true end
  local paths = load()
  if paths[workspace] then return true end
  paths[workspace] = true
  local path = filename()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
  local temporary = path .. '.tmp.' .. vim.fn.getpid() .. '.' .. vim.uv.hrtime()
  local fd, err = vim.uv.fs_open(temporary, 'wx', 384) -- 0600
  if not fd then return false, tostring(err) end
  local data = vim.json.encode(paths)
  local written, write_err = vim.uv.fs_write(fd, data, 0)
  vim.uv.fs_close(fd)
  if written ~= #data then
    vim.uv.fs_unlink(temporary)
    return false, tostring(write_err or 'Incomplete write')
  end
  local renamed, rename_err = vim.uv.fs_rename(temporary, path)
  if not renamed then vim.uv.fs_unlink(temporary); return false, tostring(rename_err) end
  return true
end

function M.list()
  local paths = load()
  paths[require('codeit.chat.storage').workspace()] = true
  for _, chat in ipairs(require('codeit.chat.storage').list_all()) do paths[chat.workspace] = true end
  local workspaces = {}
  for path in pairs(paths) do workspaces[#workspaces + 1] = path end
  local entries = require('codeit.tools.approval').list_workspace_trust(workspaces)
  return vim.tbl_filter(function(entry) return not is_temporary(entry.workspace) end, entries)
end

return M
