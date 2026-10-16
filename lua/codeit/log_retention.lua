local M = {}
local retention = 3 * 24 * 60 * 60
local timestamp_pattern = '%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d'
local timer

local function prune(path, format)
  local lines = vim.fn.readfile(path)
  local cutoff = os.date('!%Y-%m-%dT%H:%M:%S', os.time() - retention)
  local kept, keep, changed = {}, true, false
  for _, line in ipairs(lines) do
    local timestamp
    if format == 'provider' then
      timestamp = line:match('^%[(' .. timestamp_pattern .. ')Z%] ')
      -- Response bodies and multiline errors belong to the preceding entry.
      if timestamp then keep = timestamp >= cutoff end
    else
      local ok, entry = pcall(vim.json.decode, line)
      if ok and type(entry) == 'table' and type(entry.timestamp) == 'string' then
        timestamp = entry.timestamp:match('^(' .. timestamp_pattern .. ')[%.Z]')
      end
      keep = not timestamp or timestamp >= cutoff
    end
    if keep then kept[#kept + 1] = line else changed = true end
  end
  if not changed then return end

  -- Replace atomically so a failed cleanup cannot truncate the existing log.
  local data = #kept > 0 and table.concat(kept, '\n') .. '\n' or ''
  local fd, temporary = vim.uv.fs_mkstemp(path .. '.XXXXXX') -- 0600
  if not fd then error(temporary) end
  local written, write_err = vim.uv.fs_write(fd, data, 0)
  local closed, close_err = vim.uv.fs_close(fd)
  if written ~= #data or not closed then
    vim.uv.fs_unlink(temporary)
    error(write_err or close_err or 'incomplete write')
  end
  local renamed, rename_err = vim.uv.fs_rename(temporary, path)
  if not renamed then
    vim.uv.fs_unlink(temporary)
    error(rename_err)
  end
end

function M.prune(path, format)
  -- Retention is best-effort and must never prevent logging or plugin setup.
  return pcall(prune, path, format)
end

function M.cleanup()
  local dir = vim.fn.stdpath('state') .. '/codeit/'
  M.prune(dir .. 'provider-errors.log', 'provider')
  M.prune(dir .. 'tool-errors.jsonl', 'tool')
end

function M.setup()
  M.cleanup()
  if timer then return end
  timer = vim.uv.new_timer()
  if not timer then return end
  timer:start(60 * 60 * 1000, 60 * 60 * 1000, vim.schedule_wrap(M.cleanup))
  timer:unref()
end

return M
