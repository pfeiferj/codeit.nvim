local M = {}
local ns = vim.api.nvim_create_namespace('codeit-write-approval')
local header_ns = vim.api.nvim_create_namespace('codeit-write-approval-header')

local function geometry()
  local width = math.max(1, math.min(vim.o.columns - 4, math.floor(vim.o.columns * 0.85)))
  local height = math.max(1, math.min(vim.o.lines - 4, math.floor(vim.o.lines * 0.8)))
  return {
    relative = 'editor', width = width, height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = 'minimal', border = 'rounded', title = ' Review file edit ', title_pos = 'center',
  }
end

local function text_lines(text)
  if text == '' then return {} end
  local lines = vim.split(text, '\n', { plain = true })
  if text:sub(-1) == '\n' then table.remove(lines) end
  return lines
end

local function preview_lines(diff)
  local before, after = text_lines(diff.before), text_lines(diff.after)
  local changes = vim.diff(diff.before, diff.after, { result_type = 'indices', ctxlen = 0 })
  local lines, highlights, hunks = {}, {}, {}
  local function add(text, group)
    lines[#lines + 1] = text
    if group then highlights[#highlights + 1] = { #lines, group } end
  end
  local next_line = 1
  for _, change in ipairs(changes) do
    local old_start, old_count, new_start, new_count = unpack(change)
    local context_end = new_count == 0 and new_start or new_start - 1
    for i = next_line, context_end do add(after[i]) end
    hunks[#hunks + 1] = #lines + 1
    for i = old_start, old_start + old_count - 1 do add(before[i], 'DiffDelete') end
    for i = new_start, new_start + new_count - 1 do add(after[i], 'DiffAdd') end
    next_line = math.max(next_line, new_start + new_count, context_end + 1)
  end
  for i = next_line, #after do add(after[i]) end
  if #lines == 0 then lines[1] = '' end
  return lines, highlights, hunks
end

--- Show the entire proposed file, with removed lines inserted next to their replacements.
--- The first buffer rows reserve space for the virtual shortcut header.
function M.show(diff, options, callback)
  local short = { once = 'Approve', always = 'Always', reject = 'Reject',
    cancel = 'Cancel', review = 'Review' }
  local labels = {}
  for _, option in ipairs(options) do
    labels[#labels + 1] = option.key .. ' ' .. (short[option.id] or option.label)
  end
  labels[#labels + 1] = 'Esc Reject'
  labels[#labels + 1] = '{ / } Hunks'
  local headers = { {} }
  local length = 0
  local width = geometry().width
  for _, label in ipairs(labels) do
    local size = vim.fn.strdisplaywidth(label)
    if length > 0 and length + 2 + size > width then
      headers[#headers + 1] = {}
      length = 0
    end
    if length > 0 then
      headers[#headers][#headers[#headers] + 1] = { '  ', 'CodeitApprovalOption' }
      length = length + 2
    end
    headers[#headers][#headers[#headers] + 1] = { label, 'CodeitApprovalOption' }
    length = length + size
  end
  local body, highlights, hunks = preview_lines(diff)
  local lines = {}
  for _ = 1, #headers do lines[#lines + 1] = '' end
  local offset = #lines
  vim.list_extend(lines, body)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local filetype = diff.filetype
  if not filetype or filetype == '' then filetype = vim.filetype.match({ filename = diff.path }) end
  if filetype and filetype ~= '' then
    vim.bo[buf].filetype = filetype
    -- Filetype syntax works even when no treesitter parser is installed.
    vim.bo[buf].syntax = filetype
    pcall(vim.treesitter.start, buf, filetype)
  end
  vim.api.nvim_set_hl(0, 'CodeitApprovalOption', { default = true, link = 'Title' })
  for _, highlight in ipairs(highlights) do
    local row = offset + highlight[1] - 1
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0,
      { end_row = row + 1, hl_group = highlight[2], hl_eol = true, priority = 200 })
  end
  for i, row in ipairs(hunks) do hunks[i] = offset + row end
  vim.bo[buf].modifiable = false
  if vim.api.nvim_get_mode().mode:sub(1, 1) == 'i' then vim.cmd.stopinsert() end
  local win = vim.api.nvim_open_win(buf, true, geometry())
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  local function update_header()
    vim.api.nvim_buf_clear_namespace(buf, header_ns, 0, -1)
    if not vim.api.nvim_win_is_valid(win) then return end
    local info = vim.fn.getwininfo(win)[1]
    if not info then return end
    local width = vim.api.nvim_win_get_width(win)
    for i, chunks in ipairs(headers) do
      local row = info.topline + i - 2
      if row >= vim.api.nvim_buf_line_count(buf) then break end
      local length = 0
      for _, chunk in ipairs(chunks) do length = length + vim.fn.strdisplaywidth(chunk[1]) end
      vim.api.nvim_buf_set_extmark(buf, header_ns, row, 0, {
        virt_text = chunks, virt_text_win_col = math.max(0, math.floor((width - length) / 2)), priority = 200,
      })
    end
  end
  update_header()
  local scroll_autocmd = vim.api.nvim_create_autocmd('WinScrolled', {
    pattern = tostring(win), callback = update_header,
  })
  local finished = false
  local function finish(choice)
    if finished then return end
    finished = true
    vim.api.nvim_del_autocmd(scroll_autocmd)
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    callback(choice)
  end
  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(win), once = true,
    callback = function() vim.schedule(function() finish(nil) end) end,
  })
  for _, option in ipairs(options) do
    vim.keymap.set('n', option.key, function() finish(option.id) end,
      { buffer = buf, nowait = true, silent = true, desc = option.label })
  end
  local function jump(forward)
    if #hunks == 0 then return end
    local current = vim.api.nvim_win_get_cursor(win)[1]
    local destination = forward and hunks[1] or hunks[#hunks]
    if forward then
      for _, line in ipairs(hunks) do
        if line > current then destination = line; break end
      end
    else
      for i = #hunks, 1, -1 do
        if hunks[i] < current then destination = hunks[i]; break end
      end
    end
    vim.api.nvim_win_set_cursor(win, { destination, 0 })
  end
  vim.keymap.set('n', '}', function() jump(true) end,
    { buffer = buf, nowait = true, silent = true, desc = 'Next change hunk' })
  vim.keymap.set('n', '{', function() jump(false) end,
    { buffer = buf, nowait = true, silent = true, desc = 'Previous change hunk' })
  vim.keymap.set('n', '<Esc>', function() finish(nil) end,
    { buffer = buf, nowait = true, silent = true, desc = 'Reject file edit' })
end

return M
