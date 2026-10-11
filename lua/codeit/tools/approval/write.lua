local M = {}
local ns = vim.api.nvim_create_namespace('codeit-write-approval')
local header_ns = vim.api.nvim_create_namespace('codeit-write-approval-header')
local hunk_ns = vim.api.nvim_create_namespace('codeit-write-approval-hunks')

local function geometry(path)
  local title = ' Review file edit '
  if path and path ~= '' then
    title = ' Review file edit: ' .. vim.fn.fnamemodify(path, ':.'):gsub('%c', '?') .. ' '
  end
  local width = math.max(1, vim.o.columns - 4)
  local height = math.max(1, vim.o.lines - 6)
  return {
    relative = 'editor', width = width, height = height,
    row = math.max(0, math.floor((vim.o.lines - height - 2) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = 'minimal', border = 'rounded', title = title, title_pos = 'center',
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
      .. (option.id == 'once' and ' (Enter)' or '')
  end
  if diff.warning then table.insert(labels, 1, diff.warning) end
  labels[#labels + 1] = 'Esc Reject'
  labels[#labels + 1] = 'Ctrl-G Chat / Back'
  local body, highlights, hunks = preview_lines(diff)
  local counter_width = #tostring(#hunks)
  local hunk_label = '{ / } Hunks ' .. #hunks .. '/' .. #hunks
  labels[#labels + 1] = hunk_label
  local headers = { {} }
  local length = 0
  local width = geometry().width
  for _, label in ipairs(labels) do
    if diff.warning and label ~= diff.warning and #headers == 1 then
      headers[#headers + 1] = {}
      length = 0
    end
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
  vim.api.nvim_set_hl(0, 'CodeitApprovalHunk', { default = true, link = 'Title' })
  for i, row in ipairs(hunks) do
    hunks[i] = offset + row
    vim.api.nvim_buf_set_extmark(buf, hunk_ns, hunks[i] - 1, 0, {
      virt_text = { { ' Hunk ' .. i .. '/' .. #hunks, 'CodeitApprovalHunk' } },
      virt_text_pos = 'eol', hl_mode = 'combine', priority = 200,
    })
  end
  vim.bo[buf].modifiable = false
  if vim.api.nvim_get_mode().mode:sub(1, 1) == 'i' then vim.cmd.stopinsert() end
  local frame = geometry(diff.path)
  local close_pane = require('codeit.assistant_pane').open(frame)
  local win = vim.api.nvim_open_win(buf, true, frame)
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false
  vim.api.nvim_win_set_cursor(win, { hunks[1] or 1, 0 })
  local function update_header()
    vim.api.nvim_buf_clear_namespace(buf, header_ns, 0, -1)
    if not vim.api.nvim_win_is_valid(win) then return end
    local info = vim.fn.getwininfo(win)[1]
    if not info then return end
    local width = vim.api.nvim_win_get_width(win)
    local current = #hunks > 0 and 1 or 0
    local cursor = vim.api.nvim_win_get_cursor(win)[1]
    for i, line in ipairs(hunks) do
      if line > cursor then break end
      current = i
    end
    for _, chunks in ipairs(headers) do
      for _, chunk in ipairs(chunks) do
        if chunk[1]:sub(1, 11) == '{ / } Hunks' then
          chunk[1] = '{ / } Hunks ' .. string.format('%' .. counter_width .. 'd', current) .. '/' .. #hunks
        end
      end
    end
    for i, chunks in ipairs(headers) do
      local row = info.topline + i - 2
      if row >= vim.api.nvim_buf_line_count(buf) then break end
      local length = 0
      for _, chunk in ipairs(chunks) do length = length + vim.fn.strdisplaywidth(chunk[1]) end
      local left = math.max(0, math.floor((width - length) / 2))
      local padded = { { string.rep(' ', left), 'CodeitApprovalOption' } }
      vim.list_extend(padded, chunks)
      padded[#padded + 1] = { string.rep(' ', math.max(0, width - length - left)), 'CodeitApprovalOption' }
      vim.api.nvim_buf_set_extmark(buf, header_ns, row, 0, {
        virt_text = padded, virt_text_win_col = 0, hl_mode = 'replace', priority = 200,
      })
    end
  end
  local function focus_hunk(line)
    vim.api.nvim_win_set_cursor(win, { line, 0 })
    vim.api.nvim_win_call(win, function()
      local context = math.min(6, vim.api.nvim_win_get_height(win) - 1)
      vim.fn.winrestview({ topline = math.max(1, line - context), topfill = 0 })
    end)
    update_header()
  end
  if hunks[1] then focus_hunk(hunks[1]) else update_header() end
  local scroll_autocmd = vim.api.nvim_create_autocmd('WinScrolled', {
    pattern = tostring(win), callback = update_header,
  })
  local cursor_autocmd = vim.api.nvim_create_autocmd('CursorMoved', {
    buffer = buf, callback = update_header,
  })
  local close_chat = require('codeit.popup_chat').attach(win)
  local finished = false
  local function finish(choice)
    if finished then return end
    finished = true
    close_chat()
    close_pane()
    vim.api.nvim_del_autocmd(scroll_autocmd)
    -- Buffer-local autocmds may already be gone after bufhidden=wipe.
    pcall(vim.api.nvim_del_autocmd, cursor_autocmd)
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
    if option.id == 'once' then
      vim.keymap.set('n', '<CR>', function() finish('once') end,
        { buffer = buf, nowait = true, silent = true, desc = 'Approve file edit once' })
    end
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
    focus_hunk(destination)
  end
  vim.keymap.set('n', '}', function() jump(true) end,
    { buffer = buf, nowait = true, silent = true, desc = 'Next change hunk' })
  vim.keymap.set('n', '{', function() jump(false) end,
    { buffer = buf, nowait = true, silent = true, desc = 'Previous change hunk' })
  vim.keymap.set('n', '<Esc>', function() finish(nil) end,
    { buffer = buf, nowait = true, silent = true, desc = 'Reject file edit' })
end

return M
