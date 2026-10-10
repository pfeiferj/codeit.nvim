local M = {}

-- Resolve the integration, not the user's current workspace (including symlink installs).
local source = debug.getinfo(1, 'S').source:sub(2)
local directory = vim.fn.fnamemodify(vim.uv.fs_realpath(source) or source, ':h:h:h')
local warned = false
local function warn(err)
  if warned then return end
  warned = true
  vim.schedule(function()
    vim.notify('codeit: cannot write failed-tool log: ' .. tostring(err), vim.log.levels.WARN)
  end)
end

function M.start(name, args, raw_arguments)
  local seconds, microseconds = vim.uv.gettimeofday()
  local commit = vim.NIL
  -- Capture HEAD at invocation, before approval or asynchronous execution.
  local ok, result = pcall(function()
    return vim.system({ 'git', '-C', directory, '-c', 'core.fsmonitor=false',
      'rev-parse', '--verify', 'HEAD' }, { text = true }):wait(1000)
  end)
  if ok and result.code == 0 then
    local hash = vim.trim(result.stdout or '')
    if hash:match('^%x+$') then commit = hash end
  end
  return {
    timestamp = os.date('!%Y-%m-%dT%H:%M:%S', seconds) .. string.format('.%06dZ', microseconds),
    integration_commit = commit,
    tool = name or vim.NIL,
    arguments = args == nil and vim.NIL or vim.deepcopy(args),
    raw_arguments = raw_arguments,
  }
end

function M.failed(name, result)
  if type(result) ~= 'string' then return false end
  if result:match('^Error:') or result:match('^Rejected') then return true end
  local code = result:match('\n%[exit code: (%-?%d+)%]%s*$')
  if result:match('\n%[exit code: %-?%d+%] %[timed out%]$') then return true end
  -- ripgrep's no-match exit status is an ordinary search result.
  return code ~= nil and code ~= '0' and not (name == 'search_workspace' and code == '1')
end

local function append(entry, result)
  local dir = vim.fn.stdpath('state') .. '/codeit'
  vim.fn.mkdir(dir, 'p')
  local ok, err = vim.uv.fs_chmod(dir, 448) -- 0700
  if not ok then error(err) end
  local data = vim.json.encode(vim.tbl_extend('force', entry, { error = result })) .. '\n'
  local fd, open_err = vim.uv.fs_open(dir .. '/tool-errors.jsonl', 'a', 384) -- 0600
  if not fd then error(open_err) end
  local secured, chmod_err = vim.uv.fs_fchmod(fd, 384)
  if not secured then vim.uv.fs_close(fd); error(chmod_err) end
  local written, write_err = vim.uv.fs_write(fd, data, -1)
  vim.uv.fs_close(fd)
  if written ~= #data then error(write_err or 'incomplete write') end
end

function M.finish(entry, result, signal)
  if not entry or signal == 'cancel' or not M.failed(entry.tool, result) then return end
  local ok, err = pcall(append, entry, result)
  if not ok then warn(err) end
end

return M
