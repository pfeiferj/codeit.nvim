local M = {}
local sources = require('codeit.context.sources')

local function skill_roots(workspace)
  local roots = {}
  for _, base in ipairs(sources.globals()) do
    roots[#roots + 1] = { path = base .. '/skills', base = base }
  end
  local home = vim.uv.fs_realpath(vim.fn.expand('~'))
  if home then roots[#roots + 1] = { path = home .. '/.agents/skills', base = home .. '/.agents' } end
  roots[#roots + 1] = { path = workspace .. '/.agents/skills', base = workspace }
  roots[#roots + 1] = { path = workspace .. '/.claude/skills', base = workspace }
  return roots
end

function M.discover(workspace, mode)
  local result = {}
  for _, root in ipairs(skill_roots(workspace)) do
    local scan = vim.uv.fs_scandir(root.path)
    if scan then
      while true do
        local name = vim.uv.fs_scandir_next(scan)
        if not name then break end
        if name:match('^[%w_%-]+$') then
          for _, path in ipairs(sources.matching_files(root.path .. '/' .. name, { ['skill.md'] = true })) do
            local content = sources.read(path, root.base, workspace, mode)
            if content then
              local frontmatter = require('codeit.skills.frontmatter')
              result[name] = { path = path, content = content, description = frontmatter.description(content) or name,
                manual_only = frontmatter.disable_model_invocation(content) }
              break
            end
          end
        end
      end
    end
  end
  return result
end

function M.get(name, workspace, mode, manual, excluded)
  if type(name) ~= 'string' or not name:match('^[%w_%-]+$') or not mode then return nil end
  local skill = M.discover(workspace, mode)[name]
  return skill and (manual or not skill.manual_only) and not excluded(workspace, skill.path) and skill or nil
end

return M
