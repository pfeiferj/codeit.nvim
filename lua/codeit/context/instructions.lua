local M = {}
local sources = require('codeit.context.sources')

local function instructions(dir, base, workspace, mode, result)
  for _, path in ipairs(sources.matching_files(dir, { ['claude.md'] = true, ['agents.md'] = true })) do
    local content = sources.read(path, base, workspace, mode)
    if content then result[#result + 1] = { path = path, content = content } end
  end
end

local function directories(workspace, paths)
  local result, seen = { workspace }, { [workspace] = true }
  for _, path in ipairs(paths or {}) do
    if type(path) == 'string' then
      local absolute = vim.fn.fnamemodify(path:sub(1, 1) == '/' and path or workspace .. '/' .. path, ':p'):gsub('/+$', '')
      local real = vim.uv.fs_realpath(absolute)
      local parent = vim.uv.fs_realpath(vim.fn.fnamemodify(absolute, ':h'))
      if sources.within(absolute, workspace) and parent and sources.within(parent, workspace)
        and (not real or sources.within(real, workspace)) then
        local chain = {}
        while parent ~= workspace and not seen[parent] do
          table.insert(chain, 1, parent)
          parent = vim.fn.fnamemodify(parent, ':h')
        end
        for _, dir in ipairs(chain) do
          seen[dir] = true
          result[#result + 1] = dir
        end
      end
    end
  end
  return result
end

function M.discover(workspace, mode, paths)
  local files = {}
  for _, base in ipairs(sources.globals()) do instructions(base, base, workspace, mode, files) end
  for _, dir in ipairs(directories(workspace, paths)) do instructions(dir, workspace, workspace, mode, files) end
  return files
end
return M
