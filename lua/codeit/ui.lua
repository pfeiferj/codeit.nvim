local M = {}
local markdown = require('codeit.markdown')

local transcript, transcript_win
local draft_start = 2 -- zero-based first line of the draft
local billing_line
local header_ns = vim.api.nvim_create_namespace('codeit_sticky_header')

local function update_header()
  if not transcript or not vim.api.nvim_buf_is_valid(transcript) then return end
  vim.api.nvim_buf_clear_namespace(transcript, header_ns, 0, -1)
  if not transcript_win or not vim.api.nvim_win_is_valid(transcript_win) then return end
  local info = vim.fn.getwininfo(transcript_win)[1]
  if not billing_line or not info or info.topline <= 2 then return end
  local width = vim.api.nvim_win_get_width(transcript_win)
  local count = vim.api.nvim_buf_line_count(transcript)
  local row = info.topline - 1
  if row >= count then return end
  vim.api.nvim_buf_set_extmark(transcript, header_ns, row, 0, {
    virt_text = { { billing_line .. string.rep(' ', math.max(0, width - vim.fn.strdisplaywidth(billing_line))), 'WinBar' } },
    virt_text_win_col = 0,
    priority = 200,
  })
end

vim.api.nvim_create_autocmd('WinScrolled', {
  callback = function(args)
    if tonumber(args.match) == transcript_win then update_header() end
  end,
})

local function valid(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function scratch()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, 'codeit://chat')
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  markdown.enable(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '## Message', '', '' })
  return buf
end

local function focus_draft()
  if valid(transcript_win) then
    vim.api.nvim_set_current_win(transcript_win)
    vim.api.nvim_win_set_cursor(transcript_win, { math.max(draft_start + 1, vim.api.nvim_buf_line_count(transcript)), 0 })
  end
end

function M.is_open()
  return valid(transcript_win)
end

function M.open(on_send, on_close)
  if M.is_open() then
    focus_draft()
    return
  end
  M.close()
  if not transcript or not vim.api.nvim_buf_is_valid(transcript) then
    transcript = scratch()
    draft_start = 2
  end
  vim.cmd('botright 70vsplit')
  transcript_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(transcript_win, transcript)
  vim.wo[transcript_win].wrap = true
  vim.wo[transcript_win].number = false
  vim.wo[transcript_win].relativenumber = false
  vim.keymap.set('n', '<CR>', on_send, { buffer = transcript, desc = 'Send codeit message' })
  vim.keymap.set('i', '<C-s>', function()
    vim.cmd('stopinsert')
    on_send()
  end, { buffer = transcript, desc = 'Send codeit message' })
  vim.keymap.set('n', 'q', on_close, { buffer = transcript, desc = 'Close codeit chat' })
  focus_draft()
end

function M.close()
  if valid(transcript_win) then vim.api.nvim_win_close(transcript_win, true) end
  transcript_win = nil
  if transcript and vim.api.nvim_buf_is_valid(transcript) then
    vim.api.nvim_buf_clear_namespace(transcript, header_ns, 0, -1)
  end
end

-- Ignore close events from an earlier session if the chat has since reopened.
vim.api.nvim_create_autocmd('WinClosed', {
  callback = function(args)
    local closed = tonumber(args.match)
    if closed ~= transcript_win then return end
    vim.schedule(function()
      if closed == transcript_win then M.close() end
    end)
  end,
})

function M.take_input()
  if not transcript or not vim.api.nvim_buf_is_valid(transcript) then return nil end
  local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(transcript, draft_start, -1, false), '\n'))
  if text == '' then return nil end
  vim.api.nvim_buf_set_lines(transcript, draft_start, -1, false, { '' })
  focus_draft()
  return text
end

function M.render(messages, status, provider, model, billing)
  if not transcript or not vim.api.nvim_buf_is_valid(transcript) then return end
  local lines = { '# Codeit (' .. provider .. ': ' .. model .. ')' }
  if billing then table.insert(lines, '> ' .. billing) end
  billing_line = billing
  table.insert(lines, '')
  for _, message in ipairs(messages) do
    if message.role ~= 'system' then
      local label = ({ user = 'You', assistant = 'Assistant', tool = 'Tool' })[message.role] or message.role
      if message.role == 'tool' then label = 'Tool: ' .. (message.name or message.tool_call_id or '') end
      table.insert(lines, '## ' .. label)
      local content = message.content
      if type(content) == 'table' then
        local parts = {}
        for _, part in ipairs(content) do
          if part.type == 'text' then table.insert(parts, part.text or '') end
        end
        content = table.concat(parts, '\n')
      end
      if type(content) == 'string' and content ~= '' then
        vim.list_extend(lines, vim.split(content, '\n', { plain = true }))
      end
      for _, call in ipairs(message.tool_calls or {}) do
        table.insert(lines, '*Calling `' .. (call['function'] and call['function'].name or 'unknown tool') .. '`…*')
      end
      table.insert(lines, '')
    end
  end
  if status and status ~= '' then table.insert(lines, '* ' .. status) end
  table.insert(lines, '')
  table.insert(lines, '## Message')
  table.insert(lines, '')
  local cursor, draft_row
  if valid(transcript_win) then
    cursor = vim.api.nvim_win_get_cursor(transcript_win)
    if cursor[1] > draft_start then draft_row = cursor[1] - draft_start end
  end
  vim.api.nvim_buf_set_lines(transcript, 0, draft_start, false, lines)
  draft_start = #lines
  if draft_row then
    vim.api.nvim_win_set_cursor(transcript_win, {
      math.min(draft_start + draft_row, vim.api.nvim_buf_line_count(transcript)), cursor[2],
    })
  end
  update_header()
end

function M.show_context(request, summary, on_save)
  local existing = vim.fn.bufnr('codeit://context')
  if existing ~= -1 then
    local old_win = vim.fn.bufwinid(existing)
    if old_win ~= -1 then vim.api.nvim_win_close(old_win, true) end
    if vim.api.nvim_buf_is_valid(existing) then vim.api.nvim_buf_delete(existing, { force = true }) end
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, 'codeit://context')
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  markdown.enable(buf)
  local prefix = { '# Current context', '', 'This is the message context for the next request (tool definitions not shown).',
    'Only the compacted summary can be edited; save with :w or <C-s>. Press q to close.', '',
    '## System prompt (read-only)' }
  vim.list_extend(prefix, vim.split(request[1] and request[1].content or '', '\n', { plain = true }))
  vim.list_extend(prefix, { '', '## Compacted summary (editable)', '' })
  local suffix = { '', '## Recent messages (read-only)', '' }
  local first = summary and 3 or 2
  for i = first, #request do
    local message = request[i]
    suffix[#suffix + 1] = '### ' .. message.role
    vim.list_extend(suffix, vim.split(vim.json.encode(message), '\n', { plain = true }))
    suffix[#suffix + 1] = ''
  end
  if not summary then
    suffix[1] = ''
    suffix[2] = '## Conversation messages (read-only)'
  end
  local body = summary and vim.split(summary, '\n', { plain = true }) or { '(No compacted summary. Run :CodeitCompact to create one.)' }
  local lines = vim.list_extend(vim.deepcopy(prefix), body)
  vim.list_extend(lines, suffix)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  vim.cmd('botright 70vsplit')
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].wrap = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.keymap.set('n', 'q', function()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end, { buffer = buf, desc = 'Close context view' })
  vim.keymap.set({ 'n', 'i' }, '<C-s>', function()
    if vim.api.nvim_get_mode().mode:sub(1, 1) == 'i' then vim.cmd('stopinsert') end
    vim.cmd('write')
  end, { buffer = buf, desc = 'Save compacted context summary' })
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buffer = buf,
    callback = function()
      local current = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local function matches(chunk, start)
        for i, line in ipairs(chunk) do
          if current[start + i - 1] ~= line then return false end
        end
        return true
      end
      if #current < #prefix + #suffix or not matches(prefix, 1)
        or not matches(suffix, #current - #suffix + 1) then
        return vim.notify('codeit: only the compacted summary may be edited', vim.log.levels.ERROR)
      end
      local edited = table.concat(vim.list_slice(current, #prefix + 1, #current - #suffix), '\n')
      local ok, err = on_save(edited)
      if not ok then return vim.notify('codeit: ' .. err, vim.log.levels.ERROR) end
      vim.bo[buf].modified = false
      vim.notify('codeit: context summary saved')
    end,
  })
  vim.api.nvim_win_set_cursor(win, { #prefix + 1, 0 })
end

return M
