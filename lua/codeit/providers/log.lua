local M = {}

function M.error(config, err, detail)
  local dir = vim.fn.stdpath('state') .. '/codeit'
  local made = vim.fn.mkdir(dir, 'p')
  if made == 0 and vim.fn.isdirectory(dir) == 0 then return end
  local path = dir .. '/provider-errors.log'
  require('codeit.log_retention').prune(path, 'provider')
  local fd = vim.uv.fs_open(path, 'a', 384) -- 0600 for new logs
  if not fd then return end
  local entry = string.format('[%s] %s/%s: %s\n', os.date('!%Y-%m-%dT%H:%M:%SZ'),
    tostring(config.provider), tostring(config.model), tostring(err))
  if detail and detail ~= '' then entry = entry .. 'Response: ' .. tostring(detail) .. '\n' end
  vim.uv.fs_write(fd, entry, -1)
  vim.uv.fs_close(fd)
end

return M
