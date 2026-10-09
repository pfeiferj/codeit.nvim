local M = {}
local versions = {}

function M.refresh(id)
  if vim.bo[id].modified or vim.api.nvim_buf_get_name(id) == '' then return end
  if not vim.uv.fs_stat(vim.api.nvim_buf_get_name(id)) then return end
  local version = M.disk_version(id)
  if versions[id] == version then return end
  -- checktime can miss same-size changes within one filesystem timestamp tick.
  local readonly, modifiable = vim.bo[id].readonly, vim.bo[id].modifiable
  local ok, err = pcall(vim.api.nvim_buf_call, id, function() vim.cmd('silent noautocmd keepalt edit!') end)
  vim.bo[id].readonly, vim.bo[id].modifiable = readonly, modifiable
  if not ok then error(err) end
  versions[id] = version
end

function M.remember(id, reads)
  local disk = M.disk_version(id)
  if not vim.bo[id].modified then versions[id] = disk end
  if reads then reads[id] = { tick = vim.api.nvim_buf_get_changedtick(id), disk = disk } end
end

function M.was_read(id, reads)
  if not reads then return true end -- Standalone callers may choose their own policy.
  local previous = reads[id]
  return previous and previous.tick == vim.api.nvim_buf_get_changedtick(id) and previous.disk == M.disk_version(id)
end

function M.disk_version(id)
  local path = vim.api.nvim_buf_get_name(id)
  local stat = vim.uv.fs_stat(path)
  if not stat then return '' end
  local file = io.open(path, 'rb')
  if not file then return vim.json.encode(stat) end
  local text = file:read(200001)
  file:close()
  -- Access time changes when we read the file; it is not a content revision.
  return vim.json.encode({ dev = stat.dev, ino = stat.ino, size = stat.size,
    mode = stat.mode, mtime = stat.mtime, ctime = stat.ctime }) .. vim.fn.sha256(text or '')
end

-- Bound encoded line data, not just raw bytes: JSON escaping can expand it.
function M.read(id, start, last)
  local count = vim.api.nvim_buf_line_count(id)
  local requested = math.min(last or count, count)
  last = math.min(requested, start + 199)
  local lines, bytes = {}, 2
  for row = start, last do
    local line = vim.api.nvim_buf_get_lines(id, row - 1, row, false)[1]
    local size = #vim.json.encode(line) + 1
    if bytes + size > 20000 then
      if #lines == 0 then return nil, 'Line exceeds 20000 encoded bytes; use an approved command to inspect it in chunks' end
      break
    end
    lines[#lines + 1], bytes = line, bytes + size
  end
  local ending = start + #lines - 1
  return { start_line = start, end_line = ending, lines = lines, total_lines = count,
    truncated = ending < requested,
    next_start_line = ending < count and ending + 1 or nil,
    modified = vim.bo[id].modified }
end

return M
