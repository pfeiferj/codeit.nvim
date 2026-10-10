local M = {}
local markdown = require('codeit.markdown')
local slash_commands = require('codeit.slash_commands')

local transcript, transcript_win
local sidebar_win
local chat_lines = {}
local draft_start = 2 -- zero-based first line of the draft
local billing_line
local ui_ns = vim.api.nvim_create_namespace('codeit_chat_ui')
local tool_folds = {}
local role_marks = {}
local can_send_message = true
local draft_status
for group, link in pairs({ CodeitUser = 'Special', CodeitAssistant = 'Title', CodeitTool = 'Comment' }) do
  vim.api.nvim_set_hl(0, group, { default = true, link = link })
end
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
  for _, win in ipairs({ transcript_win, sidebar_win }) do
    if vim.api.nvim_win_is_valid(win) then
      vim.wo[win].winbar = billing_line and ('%#WinBar#' .. billing_line:gsub('%%', '%%%%')) or ''
    end
  end
end

local function draft_hint()
  if not transcript or not vim.api.nvim_buf_is_valid(transcript) then return end
  local hint = can_send_message and 'Ctrl-S: send · Enter: newline (insert mode) · normal Enter: send'
    or 'Sending unavailable while busy · Your draft is kept'
  if draft_status and draft_status ~= '' then hint = draft_status .. ' · ' .. hint end
  vim.api.nvim_buf_set_extmark(transcript, ui_ns, draft_start - 2, 0, {
    virt_lines = { { { hint, 'Comment' } } },
  })
end

function M.tool_foldtext()
  local summary = (vim.b.codeit_fold_summaries or {})[tostring(vim.v.foldstart)]
  if not summary then return vim.fn.getline(vim.v.foldstart) end
  local suffix = ' … (' .. summary.count .. ' lines · za: expand)'
  local preview = summary.preview:gsub('\t', ' ')
  local width = math.max(0, vim.api.nvim_win_get_width(0) - vim.fn.strdisplaywidth(suffix) - 2)
  preview = vim.fn.strcharpart(preview, 0, width)
  while vim.fn.strdisplaywidth(preview) > width do
    preview = vim.fn.strcharpart(preview, 0, vim.fn.strchars(preview) - 1)
  end
  return '  ' .. preview .. suffix
end

--- Configure folds and role styling in both interactive and read-only chat windows.
function M.decorate_chat(win, expanded)
  local buf = vim.api.nvim_win_get_buf(win)
  local summaries = {}
  for _, fold in ipairs(tool_folds) do
    summaries[tostring(fold.first)] = { preview = fold.preview, count = fold.count }
  end
  vim.b[buf].codeit_fold_summaries = summaries
  vim.wo[win].foldmethod = 'manual'
  vim.wo[win].foldenable = true
  vim.wo[win].foldlevel = 0
  vim.wo[win].foldminlines = 0
  vim.wo[win].foldtext = 'v:lua.require("codeit.ui").tool_foldtext()'
  vim.api.nvim_win_call(win, function()
    local view = vim.fn.winsaveview()
    vim.cmd('silent! normal! zE')
    for _, fold in ipairs(tool_folds) do
      vim.cmd(fold.first .. ',' .. fold.last .. 'fold')
      if expanded and expanded[fold.key] then vim.cmd(fold.first .. 'foldopen') end
    end
    vim.fn.winrestview(view)
  end)
  vim.api.nvim_buf_clear_namespace(buf, ui_ns, 0, -1)
  for _, mark in ipairs(role_marks) do
    vim.api.nvim_buf_set_extmark(buf, ui_ns, mark.row, 0, {
      end_col = #mark.text, hl_group = mark.group, priority = 200,
    })
  end
  local turns = {}
  for _, mark in ipairs(role_marks) do
    if mark.group == 'CodeitUser' then turns[#turns + 1] = mark.row + 1 end
  end
  local function move_turn(direction)
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local target, remaining = nil, vim.v.count1
    local first = direction == 1 and 1 or #turns
    local last = direction == 1 and #turns or 1
    for index = first, last, direction do
      if (turns[index] - row) * direction > 0 then
        target = turns[index]
        remaining = remaining - 1
        if remaining == 0 then break end
      end
    end
    if target then vim.api.nvim_win_set_cursor(0, { target, 0 }) end
  end
  vim.keymap.set('n', '{', function() move_turn(-1) end,
    { buffer = buf, silent = true, desc = 'Previous chat turn' })
  vim.keymap.set('n', '}', function() move_turn(1) end,
    { buffer = buf, silent = true, desc = 'Next chat turn' })
  if buf == transcript then draft_hint() end
end

local function expanded_folds(win)
  local expanded = {}
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_call(win, function()
      for _, fold in ipairs(tool_folds) do
        if vim.fn.foldclosed(fold.first) == -1 then expanded[fold.key] = true end
      end
    end)
  end
  return expanded
end

local function valid(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function scratch()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, 'codeit://chat')
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  markdown.enable(buf)
  local lines = vim.deepcopy(chat_lines)
  if #lines > 0 then table.insert(lines, '') end
  vim.list_extend(lines, { '## Message', '', '' })
  draft_start = #lines - 1
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
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
  local width = math.max(1, vim.o.columns - 4)
  local height = math.max(1, vim.o.lines - 6)
  return {
    relative = 'editor', width = width, height = height,
    row = math.max(0, math.floor((vim.o.lines - height - 2) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = 'minimal', border = 'rounded',
    title = ' Codeit chat — Ctrl-G / Esc: back ', title_pos = 'center',
  }
end

local function restore_sidebar()
  local popup = transcript_win
  local expanded = expanded_folds(popup)
  local view
  if valid(popup) then
    vim.api.nvim_win_call(popup, function() view = vim.fn.winsaveview() end)
  end
  transcript_win, sidebar_win = sidebar_win, nil
  if valid(popup) then vim.api.nvim_win_close(popup, true) end
  if valid(transcript_win) then
    vim.api.nvim_set_current_win(transcript_win)
    M.decorate_chat(transcript_win, expanded)
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
  M.decorate_chat(popup, expanded_folds(sidebar_win))
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
  end
  vim.cmd('botright 80vsplit')
  transcript_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(transcript_win, transcript)
  vim.bo[transcript].completeopt = 'menuone,noselect'
  vim.wo[transcript_win].wrap = true
  vim.wo[transcript_win].linebreak = true
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
  M.decorate_chat(transcript_win)
  update_header()
  focus_draft()
end

function M.close()
  completion = nil
  local active, sidebar = transcript_win, sidebar_win
  transcript_win, sidebar_win = nil, nil
  if valid(active) then vim.api.nvim_win_close(active, true) end
  if valid(sidebar) then vim.api.nvim_win_close(sidebar, true) end
  if transcript and vim.api.nvim_buf_is_valid(transcript) then
    vim.api.nvim_buf_clear_namespace(transcript, ui_ns, 0, -1)
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

function M.render(messages, status, provider, model, billing, command_results, can_send)
  require('codeit.assistant_pane').set_messages(messages)
  local active_expanded = expanded_folds(transcript_win)
  local sidebar_expanded = expanded_folds(sidebar_win)
  tool_folds, role_marks = {}, {}
  can_send_message = can_send ~= false
  draft_status = status
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
      table.insert(lines, '')
      local output_lines = vim.split(result.output, '\n', { plain = true })
      local first = #lines + 1
      vim.list_extend(lines, output_lines)
      if #output_lines > 6 then
        tool_folds[#tool_folds + 1] = { first = first, last = #lines, key = result,
          preview = output_lines[1], count = #output_lines }
      end
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
      if message.role == 'user' then
        table.insert(lines, '---')
        table.insert(lines, '')
      end
      local label_text = '**' .. label .. '**'
      role_marks[#role_marks + 1] = { row = #lines, text = label_text,
        group = ({ user = 'CodeitUser', assistant = 'CodeitAssistant' })[message.role] or 'CodeitTool' }
      table.insert(lines, label_text)
      table.insert(lines, '')
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
          local fenced = markdown.fence(content, 'text')
          local first = #lines + 1
          vim.list_extend(lines, fenced)
          if #fenced > 8 then
            tool_folds[#tool_folds + 1] = { first = first, last = #lines, key = message,
              preview = fenced[2], count = #fenced - 2 }
          end
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
  if valid(transcript_win) then M.decorate_chat(transcript_win, active_expanded) end
  if valid(sidebar_win) then M.decorate_chat(sidebar_win, sidebar_expanded) end
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
