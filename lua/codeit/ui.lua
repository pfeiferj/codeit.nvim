local M = {}
local markdown = require('codeit.markdown')
local slash_commands = require('codeit.slash_commands')

local transcript, transcript_win
local sidebar_win
local chat_lines = {}
local draft_start = 2 -- zero-based first line of the draft
local billing_line
local header_ns = vim.api.nvim_create_namespace('codeit_sticky_header')
local slash_group = vim.api.nvim_create_augroup('codeit_slash_completion', { clear = true })
local completion

-- Keep the first Tab's matches even after replacing the typed prefix.
local function tab_complete()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1], cursor[2]
  local line = vim.api.nvim_get_current_line()
  local prefix = line:sub(1, col)
  local same = completion and completion.row == row and completion.col == col
    and completion.line == line
  if not same then
    completion = nil
    if row ~= draft_start + 1 or not prefix:match('^/[%w]*$') then return '<Tab>' end
    local matches = {}
    for _, item in ipairs(slash_commands.complete_items()) do
      if item.word:sub(1, #prefix) == prefix then matches[#matches + 1] = item.word end
    end
    if #matches == 0 then return '<Tab>' end
    completion = { matches = matches, index = 0, row = row }
  end
  local current = completion
  current.index = current.index % #current.matches + 1
  -- <Cmd> runs after <C-e> has dismissed the popup, without leaving insert mode.
  return (vim.fn.pumvisible() == 1 and '<C-e>' or '')
    .. '<Cmd>lua require("codeit.ui").cycle_slash()<CR>'
end

function M.cycle_slash()
  local current = completion
  if not current or not M.is_open() or vim.api.nvim_get_current_buf() ~= transcript then return end
  local row, col = current.row, vim.api.nvim_win_get_cursor(0)[2]
  if vim.api.nvim_win_get_cursor(0)[1] ~= row then return end
  local word = current.matches[current.index]
  vim.api.nvim_buf_set_text(transcript, row - 1, 0, row - 1, col, { word })
  vim.api.nvim_win_set_cursor(0, { row, #word })
  current.col = #word
  current.line = vim.api.nvim_get_current_line()
end

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

local function popup_config()
  local width = math.max(1, math.min(vim.o.columns - 4, math.floor(vim.o.columns * 0.85)))
  local height = math.max(1, math.min(vim.o.lines - 4, math.floor(vim.o.lines * 0.8)))
  return {
    relative = 'editor', width = width, height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = 'minimal', border = 'rounded',
    title = ' Codeit chat — Ctrl-G / Esc: back ', title_pos = 'center',
  }
end

local function restore_sidebar()
  local popup = transcript_win
  local view
  if valid(popup) then
    vim.api.nvim_win_call(popup, function() view = vim.fn.winsaveview() end)
  end
  transcript_win, sidebar_win = sidebar_win, nil
  if valid(popup) then vim.api.nvim_win_close(popup, true) end
  if valid(transcript_win) then
    vim.api.nvim_set_current_win(transcript_win)
    if view then vim.fn.winrestview(view) end
  end
  update_header()
end

function M.toggle_popup()
  if not M.is_open() then return end
  if sidebar_win then return restore_sidebar() end
  local view
  vim.api.nvim_win_call(transcript_win, function() view = vim.fn.winsaveview() end)
  local popup = vim.api.nvim_open_win(transcript, true, popup_config())
  sidebar_win, transcript_win = transcript_win, popup
  vim.wo[popup].wrap = true
  vim.wo[popup].linebreak = true
  vim.fn.winrestview(view)
  update_header()
end

vim.api.nvim_create_autocmd('VimResized', {
  callback = function()
    if sidebar_win and valid(transcript_win) then
      vim.api.nvim_win_set_config(transcript_win, popup_config())
      update_header()
    end
  end,
})

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
  vim.bo[transcript].completeopt = 'menuone,noselect'
  vim.wo[transcript_win].wrap = true
  vim.wo[transcript_win].number = false
  vim.wo[transcript_win].relativenumber = false
  vim.keymap.set('n', '<CR>', on_send, { buffer = transcript, desc = 'Send codeit message' })
  vim.keymap.set('i', '<C-s>', function()
    vim.cmd('stopinsert')
    on_send()
  end, { buffer = transcript, desc = 'Send codeit message' })
  vim.keymap.set('i', '<CR>', function()
    if vim.fn.pumvisible() == 1 then
      vim.schedule(function()
        if not M.is_open() then return end
        local command, args = slash_commands.parse(M.peek_input() or '')
        if command and (command.command ~= 'CodeitProvider' or args ~= '')
          and (command.command ~= 'CodeitSend' or args ~= '') then
          vim.cmd('stopinsert')
          on_send()
        end
      end)
      return '<C-y>'
    end
    local text = M.peek_input()
    if text and slash_commands.parse(text) ~= nil then
      vim.schedule(function()
        if M.is_open() then
          vim.cmd('stopinsert')
          on_send()
        end
      end)
      return ''
    end
    return '<CR>'
  end, { buffer = transcript, expr = true, desc = 'Run slash command or insert newline' })
  vim.api.nvim_clear_autocmds({ group = slash_group })
  vim.api.nvim_create_autocmd('InsertCharPre', {
    group = slash_group,
    buffer = transcript,
    callback = function()
      if vim.v.char ~= '/' or vim.api.nvim_get_current_buf() ~= transcript then return end
      local cursor = vim.api.nvim_win_get_cursor(0)
      if cursor[1] ~= draft_start + 1 or cursor[2] ~= 0 then return end
      vim.schedule(function()
        if not M.is_open() or vim.api.nvim_get_current_buf() ~= transcript
          or vim.api.nvim_get_mode().mode:sub(1, 1) ~= 'i' then return end
        local row = vim.api.nvim_win_get_cursor(0)[1]
        if row ~= draft_start + 1 or vim.api.nvim_get_current_line():sub(1, 1) ~= '/' then return end
        vim.fn.complete(1, slash_commands.complete_items())
      end)
    end,
  })
  vim.keymap.set('i', '<Tab>', tab_complete,
    { buffer = transcript, expr = true, desc = 'Complete or cycle slash commands' })
  vim.keymap.set({ 'n', 'i' }, '<C-g>', M.toggle_popup,
    { buffer = transcript, silent = true, desc = 'Toggle interactive chat popup' })
  vim.keymap.set('n', '<Esc>', function()
    if sidebar_win then restore_sidebar() end
  end, { buffer = transcript, silent = true, desc = 'Return from chat popup' })
  vim.keymap.set('n', 'q', on_close, { buffer = transcript, desc = 'Close codeit chat' })
  focus_draft()
end

function M.close()
  completion = nil
  local active, sidebar = transcript_win, sidebar_win
  transcript_win, sidebar_win = nil, nil
  if valid(active) then vim.api.nvim_win_close(active, true) end
  if valid(sidebar) then vim.api.nvim_win_close(sidebar, true) end
  if transcript and vim.api.nvim_buf_is_valid(transcript) then
    vim.api.nvim_buf_clear_namespace(transcript, header_ns, 0, -1)
  end
end

-- Ignore close events from an earlier session if the chat has since reopened.
vim.api.nvim_create_autocmd('WinClosed', {
  callback = function(args)
    local closed = tonumber(args.match)
    if closed ~= transcript_win and closed ~= sidebar_win then return end
    vim.schedule(function()
      if closed == sidebar_win then
        M.close()
      elseif closed == transcript_win then
        if valid(sidebar_win) then restore_sidebar() else M.close() end
      end
    end)
  end,
})

function M.peek_input()
  if not transcript or not vim.api.nvim_buf_is_valid(transcript) then return nil end
  local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(transcript, draft_start, -1, false), '\n'))
  if text == '' then return nil end
  return text
end

function M.take_input()
  local text = M.peek_input()
  if not text then return nil end
  completion = nil
  vim.api.nvim_buf_set_lines(transcript, draft_start, -1, false, { '' })
  focus_draft()
  return text
end

function M.render(messages, status, provider, model, billing, command_results)
  require('codeit.assistant_pane').set_messages(messages)
  local lines = { '# Codeit (' .. provider .. ': ' .. model .. ')' }
  if billing then table.insert(lines, '> ' .. billing) end
  billing_line = billing
  table.insert(lines, '')
  -- Results belong to a message boundary, not to the moving draft heading.
  local results_by_message = {}
  for _, result in ipairs(command_results or {}) do
    local index = result.after_message
    results_by_message[index] = results_by_message[index] or {}
    table.insert(results_by_message[index], result)
  end
  local function render_results(index)
    for _, result in ipairs(results_by_message[index] or {}) do
      table.insert(lines, '## Command: `' .. result.command .. '`')
      vim.list_extend(lines, vim.split(result.output, '\n', { plain = true }))
      table.insert(lines, '')
    end
  end
  render_results(0)
  local tool_names = {}
  for index, message in ipairs(messages) do
    if message.role ~= 'system' then
      local label = ({ user = 'You', assistant = 'Assistant', tool = 'Tool' })[message.role] or message.role
      if message.role == 'tool' then
        label = 'Tool: ' .. (message.name or tool_names[message.tool_call_id] or message.tool_call_id or '')
      end
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
        if message.role == 'tool' then
          table.insert(lines, '')
          vim.list_extend(lines, markdown.fence(content, 'text'))
        else
          vim.list_extend(lines, vim.split(content, '\n', { plain = true }))
        end
      end
      for _, call in ipairs(message.tool_calls or {}) do
        local name = call['function'] and call['function'].name or 'unknown tool'
        if call.id then tool_names[call.id] = name end
        table.insert(lines, '*Calling `' .. name .. '`…*')
      end
      table.insert(lines, '')
    end
    render_results(index)
  end
  if status and status ~= '' then table.insert(lines, '* ' .. status) end
  chat_lines = vim.deepcopy(lines)
  if not transcript or not vim.api.nvim_buf_is_valid(transcript) then return end
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

--- A read-only chat preview excludes the editable message draft.
function M.chat_lines()
  return vim.deepcopy(chat_lines)
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

local function editor(name, lines, filetype, decode, on_save)
  local existing = vim.fn.bufnr(name)
  if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
    local old_win = vim.fn.bufwinid(existing)
    if old_win ~= -1 then vim.api.nvim_win_close(old_win, true) end
    vim.api.nvim_buf_delete(existing, { force = true })
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = filetype
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
  end, { buffer = buf, desc = 'Close codeit editor' })
  vim.keymap.set({ 'n', 'i' }, '<C-s>', function()
    if vim.api.nvim_get_mode().mode:sub(1, 1) == 'i' then vim.cmd('stopinsert') end
    vim.cmd('write')
  end, { buffer = buf, desc = 'Save codeit editor' })
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buffer = buf,
    callback = function()
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
      local ok, value = decode(text)
      if not ok then return vim.notify('codeit: ' .. tostring(value), vim.log.levels.ERROR) end
      local saved, err = on_save(value)
      if not saved then return vim.notify('codeit: ' .. err, vim.log.levels.ERROR) end
      vim.bo[buf].modified = false
      vim.notify('codeit: editor saved')
    end,
  })
end

function M.show_context_full(messages, on_save)
  local text = require('codeit.approval_format').pretty_json(messages)
  -- JSON is intentionally the exact effective request message array, including tool metadata.
  editor('codeit://context-full', vim.split(text, '\n', { plain = true }), 'json',
    function(value) return pcall(vim.json.decode, value) end, on_save)
end

function M.show_system_prompt(prompt, on_save)
  editor('codeit://system-prompt', vim.split(prompt, '\n', { plain = true }), 'text',
    function(value) return true, value end, on_save)
end

return M
