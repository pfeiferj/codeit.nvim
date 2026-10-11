local M = {}
local disabled_workspace, disabled = nil, {}

function M.set_disabled(workspace, paths)
  disabled_workspace, disabled = workspace, paths or {}
end

local function excluded(workspace, path)
  return workspace == disabled_workspace and disabled[path] == true
end

local function within(path, base)
  return path == base or path:sub(1, #base + 1) == base .. '/'
end

local function tracked(path, workspace)
  if vim.fn.executable('git') ~= 1 then return false end
  local result = vim.system({ 'git', '--literal-pathspecs', '-c', 'core.fsmonitor=false', '-C', workspace, 'ls-files', '--error-unmatch', '--',
    path:sub(#workspace + 2) }, { text = true }):wait()
  return result.code == 0
end

local function safe_file(path, base, workspace, mode)
  if not mode or not within(path, base) then return false end
  local real = vim.uv.fs_realpath(path)
  local stat = real and vim.uv.fs_stat(real)
  -- Do not follow instruction/skill symlinks outside their configured tree.
  if not real or not within(real, base) or not stat or stat.type ~= 'file' or stat.size > 100000 then return false end
  return base ~= workspace or mode == 'all' or tracked(path, workspace)
end

local function read(path, base, workspace, mode)
  if not safe_file(path, base, workspace, mode) then return nil end
  local file = io.open(path, 'rb')
  if not file then return nil end
  local text = file:read(100001)
  file:close()
  if not text or #text > 100000 or text:find('\0', 1, true) then return nil end
  return text
end

local function globals()
  local home = vim.uv.fs_realpath(vim.fn.expand('~'))
  if not home then return {} end
  return { home .. '/.claude', home .. '/.config/codeit' }
end

local function matching_files(dir, names)
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

local function instructions(dir, base, workspace, mode, result)
  for _, path in ipairs(matching_files(dir, { ['claude.md'] = true, ['agents.md'] = true })) do
    local content = read(path, base, workspace, mode)
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
      if within(absolute, workspace) and parent and within(parent, workspace)
        and (not real or within(real, workspace)) then
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

local function skill_roots(workspace)
  local roots = {}
  for _, base in ipairs(globals()) do
    roots[#roots + 1] = { path = base .. '/skills', base = base }
  end
  local home = vim.uv.fs_realpath(vim.fn.expand('~'))
  if home then roots[#roots + 1] = { path = home .. '/.agents/skills', base = home .. '/.agents' } end
  roots[#roots + 1] = { path = workspace .. '/.agents/skills', base = workspace }
  roots[#roots + 1] = { path = workspace .. '/.claude/skills', base = workspace }
  return roots
end

local function skills(workspace, mode)
  local result = {}
  for _, root in ipairs(skill_roots(workspace)) do
    local scan = vim.uv.fs_scandir(root.path)
    if scan then
      while true do
        local name = vim.uv.fs_scandir_next(scan)
        if not name then break end
        if name:match('^[%w_%-]+$') then
          for _, path in ipairs(matching_files(root.path .. '/' .. name, { ['skill.md'] = true })) do
            local content = read(path, root.base, workspace, mode)
            if content then
              local frontmatter = require('codeit.skill_frontmatter')
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

function M.skill(name, workspace, mode)
  if type(name) ~= 'string' or not name:match('^[%w_%-]+$') or not mode then return nil end
  local skill = skills(workspace, mode)[name]
  return skill and not skill.manual_only and not excluded(workspace, skill.path) and skill or nil
end

function M.entries(workspace, mode, paths, selected)
  if not mode then return {} end
  local files = {}
  for _, base in ipairs(globals()) do instructions(base, base, workspace, mode, files) end
  for _, dir in ipairs(directories(workspace, paths)) do
    instructions(dir, workspace, workspace, mode, files)
  end
  local entries = {}
  for _, file in ipairs(files) do
    entries[#entries + 1] = { kind = 'instruction', path = file.path, content = file.content,
      included = not excluded(workspace, file.path) }
  end
  local available = skills(workspace, mode)
  local names = vim.tbl_keys(available)
  table.sort(names)
  for _, name in ipairs(names) do
    local skill = available[name]
    local available = not excluded(workspace, skill.path)
    local active = available and vim.tbl_contains(selected or {}, name)
    entries[#entries + 1] = { kind = 'skill', name = name, path = skill.path,
      description = skill.description, content = skill.content,
      included = active, available = available, manual_only = skill.manual_only,
      state = not available and 'off' or (active and 'active' or 'on') }
  end
  return entries
end

function M.messages(workspace, mode, paths, selected)
  local entries = M.entries(workspace, mode, paths, selected)
  local result, names = {}, {}
  for _, entry in ipairs(entries) do
    if entry.kind == 'instruction' and entry.included then
      result[#result + 1] = { role = 'system', content = 'Instructions from ' .. entry.path .. ':\n' .. entry.content }
    elseif entry.kind == 'skill' and entry.available and not entry.manual_only then
      names[#names + 1] = entry.name .. ': ' .. entry.description
    end
  end
  if #names > 0 then
    result[#result + 1] = { role = 'system', content = 'Available skills (call load_skill with the skill name to load its instructions before using it):\n' .. table.concat(names, '\n') }
  end
  for _, entry in ipairs(entries) do
    if entry.kind == 'skill' and entry.included then
      result[#result + 1] = { role = 'system', content = 'Selected skill ' .. entry.name .. ' (' .. entry.path .. '):\n' .. entry.content }
    end
  end
  return result
end

return M
