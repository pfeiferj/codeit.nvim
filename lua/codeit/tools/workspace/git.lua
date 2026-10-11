local M = {}
local spec = require('codeit.tools.spec')
local paths = require('codeit.tools.workspace.paths')
local runner = require('codeit.process')
local within = paths.within

M.specs = {
  spec('git_status', 'Read workspace Git status (short format, disk state only). Output at most 20000 bytes with a truncation marker; filesystem-monitor programs disabled.'),
  spec('git_diff', 'Read tracked DISK changes, including deleted paths, not untracked/unsaved buffers. Default unstaged; staged=true compares index to HEAD. base optionally compares working tree (or index with staged=true) to a commit, e.g. HEAD or main. Only one commit revision, not ranges. No external diff/textconv/fsmonitor programs. Output max 20000 bytes. Omit path/empty path for all workspace diffs.', {
    path = { type = 'string', description = 'Optional workspace path; empty returns all diffs' },
    staged = { type = 'boolean', description = 'Compare staged index instead of working tree (default false)' },
    base = { type = 'string', minLength = 1, maxLength = 200, description = 'Optional single commit revision, resolved safely before diffing' },
  }),
}

local function process(argv, cwd, done, active)
  return runner.run(argv, cwd, function(result) done(runner.format(result)) end, active)
end

local function git_path(path, base)
  -- Deleted files still have useful diffs. Validate existing ancestors, not existence.
  if type(path) ~= 'string' or path == '' or path:find('\0', 1, true) then return nil, 'Invalid path' end
  local absolute = vim.fs.normalize(path:sub(1, 1) == '/' and path or base .. '/' .. path)
  if not within(absolute, base) or absolute == base then return nil, 'Path is outside the workspace' end
  local parent = absolute
  while not vim.uv.fs_lstat(parent) do parent = vim.fn.fnamemodify(parent, ':h') end
  local real = vim.uv.fs_realpath(parent)
  if not real or not within(real, base) then return nil, 'Path resolves outside the workspace' end
  return absolute
end

function M.execute(name, args, done, active, approve, reads, prepare, source, origin)
  local base = paths.root()
  if not base then return done('Error: workspace does not exist') end
  if name == 'git_status' or name == 'git_diff' then
    if vim.fn.executable('git') ~= 1 then return done('Error: git is required') end
    local argv = { 'git', '--no-pager', '--literal-pathspecs', '-c', 'core.fsmonitor=false' }
    if name == 'git_status' then
      vim.list_extend(argv, { 'status', '--short', '--untracked-files=all', '--', '.' })
    else
      vim.list_extend(argv, { 'diff', '--no-ext-diff', '--no-textconv' })
      if args.staged then argv[#argv + 1] = '--cached' end
      if args.base then
        if args.base:find('%c') or args.base:sub(1, 1) == '-' then return done('Error: invalid base revision') end
        local verify = { 'git', '--no-pager', '-c', 'core.fsmonitor=false', 'rev-parse', '--verify',
          '--end-of-options', args.base .. '^{commit}' }
        return runner.run(verify, base, function(result)
          local revision = vim.trim(result.stdout or '')
          if result.code ~= 0 or not revision:match('^%x+$') then
            return done('Error: base must resolve to one commit\n' .. runner.format(result))
          end
          -- The resolved hash cannot be interpreted as an option or path.
          argv[#argv + 1] = revision
          argv[#argv + 1] = '--'
          if args.path ~= nil and args.path ~= '' then
            local path, err = git_path(args.path, base)
            if not path then return done('Error: ' .. err) end
            argv[#argv + 1] = path
          else argv[#argv + 1] = '.' end
          process(argv, base, done, active)
        end, active)
      end
      argv[#argv + 1] = '--'
      if args.path ~= nil and args.path ~= '' then
        local path, err = git_path(args.path, base)
        if not path then return done('Error: ' .. err) end
        argv[#argv + 1] = path
      else
        argv[#argv + 1] = '.'
      end
    end
    return process(argv, base, done, active)
  end
  done('Error: unknown tool ' .. tostring(name))
end

return M
