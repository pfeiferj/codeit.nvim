local next_instance = 0

--- Create an independent chat with optional presentation overrides.
local function new(options)
options = options or {}
next_instance = next_instance + 1
local M = {}
local markdown = require('codeit.markdown')
local slash_commands = require('codeit.slash_commands')

local transcript, transcript_win
local sidebar_win
local chat_lines = {}
local draft_start = 2 -- zero-based first line of the draft
local latest_prompt_row, latest_prompt_index
local billing_line
local ui_ns = vim.api.nvim_create_namespace('codeit_chat_ui')
local tool_folds = {}
local section_folds = {}
local role_marks = {}
local can_send_message = true
local draft_status
local draft_hint_id
require('codeit.highlight').setup_roles()
local slash_group = vim.api.nvim_create_augroup('codeit_chat_' .. next_instance, { clear = true })
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
  -- Apply the replacement after dismissing completion, without leaving insert mode.
  return (vim.fn.pumvisible() == 1 and '<C-e>' or '')
    .. '<Plug>(codeit-cycle-slash)'
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

local function wrap_hint(text, width)
  local lines, line = {}, ''
  for word in text:gmatch('%S+') do
    local candidate = line == '' and word or (line .. ' ' .. word)
    if vim.fn.strdisplaywidth(candidate) <= width then
      line = candidate
    else
      if line ~= '' then lines[#lines + 1], line = { { line, 'Comment' } }, '' end
      for index = 0, vim.fn.strchars(word, true) - 1 do
        local char = vim.fn.strcharpart(word, index, 1, true)
        if line ~= '' and vim.fn.strdisplaywidth(line .. char) > width then
          lines[#lines + 1], line = { { line, 'Comment' } }, ''
        end
        line = line .. char
      end
    end
  end
  if line ~= '' then lines[#lines + 1] = { { line, 'Comment' } } end
  return lines
end

local function draft_hint()
  if not transcript or not vim.api.nvim_buf_is_valid(transcript) then return end
  local width
  -- Virtual lines are buffer-wide, so they must fit both the sidebar and popup.
  for _, win in ipairs({ transcript_win, sidebar_win }) do
    if vim.api.nvim_win_is_valid(win) then
      local available = math.max(1, vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff)
      width = math.min(width or available, available)
    end
  end
  if not width then return end
  local hint = can_send_message and 'Ctrl-S: send · Enter: newline (insert mode) · normal Enter: send'
    or 'Sending unavailable while busy · Your draft is kept'
  if draft_status and draft_status ~= '' then hint = draft_status .. ' · ' .. hint end
  draft_hint_id = vim.api.nvim_buf_set_extmark(transcript, ui_ns, draft_start - 2, 0, {
    id = draft_hint_id,
    virt_lines = wrap_hint(hint, width),
  })
end

function M.tool_foldtext()
  local summary = (vim.w.codeit_fold_summaries or {})[tostring(vim.v.foldstart)]
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
  vim.wo[win].foldmethod = 'manual'
  vim.wo[win].foldenable = true
  vim.wo[win].foldlevel = 0
  vim.wo[win].foldminlines = 0
  vim.wo[win].foldtext = 'v:lua.require("codeit.ui").tool_foldtext()'
  vim.api.nvim_win_call(win, function()
    local view = vim.fn.winsaveview()
    vim.cmd('silent! normal! zE')
    -- Measure before creating any folds so nested content is counted in full.
    for _, folds in ipairs({ tool_folds, section_folds }) do
      for _, fold in ipairs(folds) do
        local height = vim.api.nvim_win_text_height(win, {
          start_row = fold.first - 1 + fold.padding,
          end_row = fold.last - 1 - fold.padding,
        })
        summaries[tostring(fold.first)] = { preview = fold.preview, count = height.all - height.fill }
      end
    end
    for _, folds in ipairs({ tool_folds, section_folds }) do
      for _, fold in ipairs(folds) do
        vim.cmd(fold.first .. ',' .. fold.last .. 'fold')
        local state = folds == section_folds and expanded and expanded.sections or expanded
        if state and state[fold.key] then vim.cmd(fold.first .. 'foldopen') end
      end
    end
    vim.w[win].codeit_fold_summaries = summaries
    vim.fn.winrestview(view)
  end)
  vim.api.nvim_buf_clear_namespace(buf, ui_ns, 0, -1)
  if buf == transcript then draft_hint_id = nil end
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
  local expanded = { sections = {} }
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_call(win, function()
      local view = vim.fn.winsaveview()
      local closed = {}
      -- Temporarily expose children to retain their state even under a closed section.
      for _, fold in ipairs(section_folds) do
        if vim.fn.foldlevel(fold.first) > 0 then
          if vim.fn.foldclosed(fold.first) == fold.first then
            closed[#closed + 1] = fold.first
            vim.cmd(fold.first .. 'foldopen')
          else
            expanded.sections[fold.key] = true
          end
        end
      end
      for _, fold in ipairs(tool_folds) do
        if vim.fn.foldlevel(fold.first) > 0 and vim.fn.foldclosed(fold.first) == -1 then
          expanded[fold.key] = true
        end
      end
      for _, row in ipairs(closed) do vim.cmd(row .. 'foldclose') end
      vim.fn.winrestview(view)
    end)
  end
  return expanded
end

local function valid(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function scratch()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, options.name or 'codeit://chat')
  vim.bo[buf].bufhidden = options.floating and 'wipe' or 'hide'
  vim.bo[buf].swapfile = false
  markdown.enable(buf)
  local lines = vim.deepcopy(chat_lines)
  if #lines > 0 then table.insert(lines, '') end
  vim.list_extend(lines, { '## ' .. (options.draft_label or 'Message'), '', '' })
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
  if options.popup_config then return options.popup_config() end
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

local function refresh_chat_folds()
  for _, win in ipairs({ transcript_win, sidebar_win }) do
    if valid(win) then M.decorate_chat(win, expanded_folds(win)) end
  end
end

vim.api.nvim_create_autocmd('VimResized', {
  group = slash_group,
  callback = function()
    if (sidebar_win or options.floating) and valid(transcript_win) then
      vim.api.nvim_win_set_config(transcript_win, popup_config())
      update_header()
    end
    refresh_chat_folds()
    draft_hint()
  end,
})

vim.api.nvim_create_autocmd('WinResized', {
  group = slash_group,
  callback = function()
    refresh_chat_folds()
    draft_hint()
  end,
})

function M.open(on_send, on_close)
  if M.is_open() then
    if not options.floating then require('codeit.managed_tab').open() end
    focus_draft()
    return
  end
  M.close()
  if not options.floating then require('codeit.managed_tab').open() end
  if not transcript or not vim.api.nvim_buf_is_valid(transcript) then
    transcript = scratch()
  end
  if options.floating then
    transcript_win = vim.api.nvim_open_win(transcript, true, popup_config())
  else
    vim.cmd('botright 80vsplit')
    transcript_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(transcript_win, transcript)
  end
  vim.bo[transcript].completeopt = 'menuone,noselect'
  vim.wo[transcript_win].wrap = true
  vim.wo[transcript_win].linebreak = true
  vim.wo[transcript_win].number = false
  vim.wo[transcript_win].relativenumber = false
  vim.keymap.set('n', '<CR>', on_send, { buffer = transcript, desc = 'Send codeit message' })
  vim.keymap.set(options.floating and { 'n', 'i' } or 'i', '<C-s>', function()
    vim.cmd('stopinsert')
    on_send()
  end, { buffer = transcript, desc = 'Send codeit message' })
  if options.slash_commands ~= false then
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
  vim.api.nvim_clear_autocmds({ group = slash_group, event = 'InsertCharPre' })
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
  vim.keymap.set('i', '<Plug>(codeit-cycle-slash)', M.cycle_slash,
    { buffer = transcript, silent = true, desc = 'Apply slash completion' })
  vim.keymap.set('i', '<Tab>', tab_complete,
    { buffer = transcript, expr = true, desc = 'Complete or cycle slash commands' })
  end
  if not options.floating then
    vim.keymap.set({ 'n', 'i' }, '<C-g>', M.toggle_popup,
      { buffer = transcript, silent = true, desc = 'Toggle interactive chat popup' })
  end
  vim.keymap.set('n', '<Esc>', function()
    if options.floating then on_close()
    elseif sidebar_win then restore_sidebar() end
  end, { buffer = transcript, silent = true, desc = 'Return from chat popup' })
  vim.keymap.set('n', 'q', on_close, { buffer = transcript, desc = 'Close codeit chat' })
  M.decorate_chat(transcript_win)
  update_header()
  focus_draft()
  return transcript_win, transcript
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
  if not options.floating then require('codeit.managed_tab').leave() end
end

-- Ignore close events from an earlier session if the chat has since reopened.
vim.api.nvim_create_autocmd('WinClosed', {
  group = slash_group,
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

local function tool_output_language(name, content)
  if name == 'run_command' then return 'bash' end
  if pcall(vim.json.decode, content) then return 'json' end
  if name == 'git_diff' then return 'diff' end
  return 'text'
end

local function follow_prompt(win, view, prompt, previous_prompt, new_turn)
  vim.api.nvim_win_call(win, function()
    local cursor = vim.api.nvim_win_get_cursor(win)
    local height = vim.api.nvim_win_text_height(win, {
      start_row = prompt - 1, end_row = cursor[1] - 1,
    }).all
    local scrolloff = vim.wo[win].scrolloff
    vim.wo[win].scrolloff = 0
    -- Let Neovim account for wrapped rows and virtual lines when the turn overflows.
    vim.cmd('normal! zb')
    if height <= vim.api.nvim_win_get_height(win) then
      local topline = prompt
      if not new_turn and previous_prompt then
        topline = math.max(1, math.min(prompt, view.topline + prompt - previous_prompt))
      end
      local bottom = vim.fn.winsaveview()
      bottom.topline, bottom.topfill, bottom.skipcol = topline, 0, 0
      vim.fn.winrestview(bottom)
    end
    vim.wo[win].scrolloff = scrolloff
  end)
end

function M.render(messages, status, provider, model, billing, command_results, can_send)
  local views = {}
  for _, win in ipairs({ transcript_win, sidebar_win }) do
    if valid(win) then
      local cursor = vim.api.nvim_win_get_cursor(win)
      vim.api.nvim_win_call(win, function()
        views[win] = { view = vim.fn.winsaveview(), cursor = cursor,
          draft_row = cursor[1] > draft_start and cursor[1] - draft_start or nil }
      end)
    end
  end
  local previous_prompt, previous_index = latest_prompt_row, latest_prompt_index
  latest_prompt_row, latest_prompt_index = nil, nil
  if not options.floating then require('codeit.assistant_pane').set_messages(messages) end
  local active_expanded = expanded_folds(transcript_win)
  local sidebar_expanded = expanded_folds(sidebar_win)
  tool_folds, section_folds, role_marks = {}, {}, {}
  can_send_message = can_send ~= false
  draft_status = status
  local lines = options.header and vim.deepcopy(options.header)
    or { '# Codeit (' .. provider .. ': ' .. model .. ')' }
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
  local section
  local function finish_section()
    if not section then return end
    section.last = #lines
    section.preview = 'Activity · ' .. section.count .. ' items'
    section_folds[#section_folds + 1] = section
    section = nil
  end
  local function start_item(key, label)
    if not section then
      section = { first = #lines + 1, key = key, padding = 0, count = 0 }
      table.insert(lines, '**Activity**')
      table.insert(lines, '')
    end
    section.count = section.count + 1
    local first = #lines + 1
    role_marks[#role_marks + 1] = { row = #lines, text = label, group = 'CodeitTool' }
    table.insert(lines, label)
    table.insert(lines, '')
    return first
  end
  local function finish_item(first, key, preview)
    tool_folds[#tool_folds + 1] = { first = first, last = #lines, key = key,
      preview = preview or lines[first], padding = 0 }
    table.insert(lines, '')
  end
  local function render_results(index)
    for _, result in ipairs(results_by_message[index] or {}) do
      local first = start_item(result, '## Command: `' .. result.command .. '`')
      vim.list_extend(lines, vim.split(result.output, '\n', { plain = true }))
      finish_item(first, result)
    end
  end
  render_results(0)
  local tool_names = {}
  for index, message in ipairs(messages) do
    if message.role ~= 'system' then
      local content = message.content
      if type(content) == 'table' then
        local parts = {}
        for _, part in ipairs(content) do
          if part.type == 'text' then table.insert(parts, part.text or '') end
        end
        content = table.concat(parts, '\n')
      end
      if message.role == 'assistant' then
        local reasoning = {}
        local function add_text(text)
          if type(text) == 'string' and text ~= '' then reasoning[#reasoning + 1] = text end
        end
        for _, detail in ipairs(message.reasoning_details or {}) do
          add_text(detail.text)
          add_text(detail.summary)
        end
        for _, item in ipairs(message._copilot_reasoning or {}) do
          for _, part in ipairs(item.summary or {}) do add_text(part.text) end
        end
        if #reasoning > 0 then
          local key = message.reasoning_details or message._copilot_reasoning
          local first = start_item(key, '**Reasoning**')
          vim.list_extend(lines, vim.split(table.concat(reasoning, '\n'), '\n', { plain = true }))
          finish_item(first, key)
        end
      end
      if message.role == 'user' or (message.role == 'assistant' and type(content) == 'string' and content ~= '') then
        finish_section()
        if message.role == 'user' then
          table.insert(lines, '---')
          table.insert(lines, '')
        end
        if message.role == 'user' then
          latest_prompt_row, latest_prompt_index = #lines + 1, index
        end
        local label = message.role == 'user' and '**You**' or ('**' .. (options.assistant_label or 'Assistant') .. '**')
        role_marks[#role_marks + 1] = { row = #lines, text = label,
          group = message.role == 'user' and 'CodeitUser' or 'CodeitAssistant' }
        table.insert(lines, label)
        table.insert(lines, '')
        if type(content) == 'string' and content ~= '' then
          vim.list_extend(lines, vim.split(content, '\n', { plain = true }))
        end
        table.insert(lines, '')
      elseif message.role ~= 'assistant' then
        local name = message.name or tool_names[message.tool_call_id] or message.tool_call_id or ''
        local label = message.role == 'tool' and ('**Tool: ' .. name .. '**') or ('**' .. message.role .. '**')
        local first = start_item(message, label)
        if type(content) == 'string' and content ~= '' then
          vim.list_extend(lines, markdown.fence(content, tool_output_language(name, content)))
        end
        finish_item(first, message, label .. (type(content) == 'string' and content ~= ''
          and (' · ' .. vim.split(content, '\n', { plain = true })[1]) or ''))
      end
      for _, call in ipairs(message.tool_calls or {}) do
        local fn = call['function'] or {}
        local name = fn.name or 'unknown tool'
        if call.id then tool_names[call.id] = name end
        local first = start_item(call, '*Calling `' .. name .. '`…*')
        local input = fn.arguments
        if type(input) == 'string' and input ~= '' then
          local ok, decoded = pcall(vim.json.decode, input)
          if ok then input = require('codeit.approval_format').pretty_json(decoded) end
          vim.list_extend(lines, markdown.fence(input, ok and 'json' or 'text'))
        end
        finish_item(first, call)
      end
    end
    render_results(index)
  end
  finish_section()
  chat_lines = vim.deepcopy(lines)
  if not transcript or not vim.api.nvim_buf_is_valid(transcript) then return end
  table.insert(lines, '')
  table.insert(lines, '## ' .. (options.draft_label or 'Message'))
  table.insert(lines, '')
  vim.api.nvim_buf_set_lines(transcript, 0, draft_start, false, lines)
  draft_start = #lines
  if valid(transcript_win) then M.decorate_chat(transcript_win, active_expanded) end
  if valid(sidebar_win) then M.decorate_chat(sidebar_win, sidebar_expanded) end
  update_header()
  for win, state in pairs(views) do
    if state.draft_row then
      vim.api.nvim_win_set_cursor(win, {
        math.min(draft_start + state.draft_row, vim.api.nvim_buf_line_count(transcript)), state.cursor[2],
      })
      if latest_prompt_row then
        follow_prompt(win, state.view, latest_prompt_row, previous_prompt, latest_prompt_index ~= previous_index)
      end
    else
      vim.api.nvim_win_call(win, function() vim.fn.winrestview(state.view) end)
    end
  end
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

function M.destroy()
  M.close()
  vim.api.nvim_del_augroup_by_id(slash_group)
end

return M
end

local M = new()
M.new = new
return M
