local M = {}

function M.within(path, base)
  return path == base or path:sub(1, #base + 1) == base .. '/'
end

local function tracked(path, workspace)
  if vim.fn.executable('git') ~= 1 then return false end
  local result = vim.system({ 'git', '--literal-pathspecs', '-c', 'core.fsmonitor=false', '-C', workspace, 'ls-files', '--error-unmatch', '--',
    path:sub(#workspace + 2) }, { text = true }):wait()
  return result.code == 0
end

local function safe_file(path, base, workspace, mode)
  if not mode or not M.within(path, base) then return false end
  local real = vim.uv.fs_realpath(path)
  local stat = real and vim.uv.fs_stat(real)
  -- Do not follow instruction/skill symlinks outside their configured tree.
  if not real or not M.within(real, base) or not stat or stat.type ~= 'file' or stat.size > 100000 then return false end
  return base ~= workspace or mode == 'all' or tracked(path, workspace)
end

function M.read(path, base, workspace, mode)
  if not safe_file(path, base, workspace, mode) then return nil end
  local file = io.open(path, 'rb')
  if not file then return nil end
  local text = file:read(100001)
  file:close()
  if not text or #text > 100000 or text:find('\0', 1, true) then return nil end
  return text
end

function M.globals()
  local home = vim.uv.fs_realpath(vim.fn.expand('~'))
  if not home then return {} end
  return { home .. '/.claude', home .. '/.config/codeit' }
end

function M.matching_files(dir, names)
  local found = {}
  local scan = vim.uv.fs_scandir(dir)
  if scan then
    while true do
      local name = vim.uv.fs_scandir_next(scan)
      if not name then break end
      if names[name:lower()] then found[#found + 1] = dir .. '/' .. name end
    end
  end
  table.sort(found)
  return found
end

return M
