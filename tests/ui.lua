vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.columns = 160 -- Leave enough room to test the default sidebar width.
local ui = require('codeit.ui')
local messages = {}
for i = 1, 50 do messages[i] = { role = 'user', content = 'message ' .. i } end
local sent
ui.open(function() sent = ui.take_input() end, ui.close)
local chat = vim.fn.bufnr('codeit://chat')
local win = vim.fn.bufwinid(chat)
assert(vim.api.nvim_win_get_width(win) == 80, 'chat sidebar should default to 80 columns')
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(chat, 0, -1, false), { '## Message', '', '' }),
  'new chats should have a blank line between the heading and draft')
assert(vim.fn.bufnr('codeit://input') == -1, 'chat must have no separate input buffer')
assert(#vim.api.nvim_list_wins() == 2, 'chat must use only one sidebar window')
assert(vim.bo[chat].filetype == 'markdown' and vim.bo[chat].syntax == 'markdown')
assert(vim.b[chat].current_syntax == 'markdown', 'Markdown syntax should be loaded')
local ns = vim.api.nvim_get_namespaces().codeit_sticky_header
assert(ns)

local function marks()
  return vim.api.nvim_buf_get_extmarks(chat, ns, 0, -1, { details = true })
end

local function scroll(topline)
  vim.api.nvim_win_call(win, function() vim.fn.winrestview({ topline = topline }) end)
  vim.api.nvim_exec_autocmds('WinScrolled', { pattern = tostring(win) })
  local actual = vim.fn.getwininfo(win)[1].topline
  assert(actual == topline, string.format('expected top line %d, got %d', topline, actual))
end

ui.render(messages, 'Ready', 'openrouter', 'model-a', 'Cost: $0.001000 | In: 100 | Out: 20 | Context: 120')
local rendered = vim.api.nvim_buf_get_lines(chat, 0, 5, false)
assert(rendered[1]:match('^# Codeit') and rendered[2]:match('^> Cost:'))
assert(rendered[4] == '---' and rendered[5] == '')
assert(vim.api.nvim_buf_get_lines(chat, 5, 6, false)[1] == '## You',
  'submitted prompts should begin a new turn after a Markdown separator')
vim.api.nvim_win_call(win, function()
  assert(vim.fn.synIDattr(vim.fn.synID(1, 1, true), 'name') ~= '',
    'chat heading should have active Markdown highlighting')
end)
scroll(1)
assert(#marks() == 0, 'do not cover the real header at the top')
scroll(2)
assert(#marks() == 0, 'do not cover the real usage line')
scroll(3)
assert(#marks() == 1 and marks()[1][2] == 2, 'usage must stick as soon as it scrolls out of view')
scroll(10)
local overlaid = marks()
assert(#overlaid == 1 and overlaid[1][2] == 9)
assert(overlaid[1][4].virt_text[1][1]:find('Cost: $0.001000 | In: 100 | Out: 20 | Context: 120', 1, true) == 1)
assert(not overlaid[1][4].virt_text[1][1]:find('# Codeit', 1, true))
assert(overlaid[1][4].virt_text_win_col == 0)
scroll(20)
assert(#marks() == 1 and marks()[1][2] == 19, 'scrolling down must move the usage mark')
scroll(19)
assert(#marks() == 1 and marks()[1][2] == 18, 'scrolling up must not duplicate usage')
scroll(18)
assert(#marks() == 1 and marks()[1][2] == 17, 'repeated reverse scrolling must not accumulate marks')
ui.render(messages, 'Ready', 'copilot', 'model-b', nil)
scroll(10)
assert(#marks() == 0, 'providers without usage must not display a sticky line')
scroll(1)
assert(#marks() == 0)

local count = vim.api.nvim_buf_line_count(chat)
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(chat, count - 3, count, false), { '## Message', '', '' }),
  'rendered chats should have a blank line between the heading and draft')
vim.api.nvim_buf_set_lines(chat, count - 1, -1, false, { 'first line', 'second line' })
vim.api.nvim_win_set_cursor(win, { count + 1, 4 })
ui.render(messages, 'Waiting', 'copilot', 'model-b', nil, nil, false)
assert(vim.api.nvim_win_get_cursor(win)[2] == 4)
assert(not vim.tbl_contains(vim.api.nvim_buf_get_lines(chat, 0, -1, false), '## Message'),
  'the draft heading should be hidden while sending is blocked')
assert(ui.peek_input() == 'first line\nsecond line', 'hiding the heading must preserve the draft')
ui.render(messages, 'Ready', 'copilot', 'model-b', nil, nil, true)
assert(vim.api.nvim_win_get_cursor(win)[2] == 4)
assert(vim.api.nvim_buf_get_lines(chat, -3, -1, false)[1] == 'first line')
assert(ui.take_input() == 'first line\nsecond line')
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(chat, -4, -1, false), { '## Message', '', '' }),
  'sending should preserve the separator')
assert(ui.take_input() == nil, 'empty drafts should not send')
ui.render({
  { role = 'assistant', content = vim.NIL, tool_calls = {
    { id = 'call_hash_1', ['function'] = { name = 'read_file', arguments = '{}' } },
    { id = 'call_hash_2', ['function'] = { name = 'git_diff', arguments = '{}' } },
  } },
  { role = 'tool', tool_call_id = 'call_hash_2', content = 'diff' },
  { role = 'tool', tool_call_id = 'call_hash_1', content = 'file' },
  { role = 'tool', tool_call_id = 'unmatched', content = 'other' },
}, 'Ready', 'copilot', 'model-b', nil)
local transcript = table.concat(vim.api.nvim_buf_get_lines(chat, 0, -1, false), '\n')
assert(transcript:find('## Tool: git_diff\n\n```text\ndiff\n```', 1, true))
assert(transcript:find('## Tool: read_file\n\n```text\nfile\n```', 1, true))
assert(transcript:find('## Tool: unmatched\n\n```text\nother\n```', 1, true), 'unmatched results retain their ID')
assert(not transcript:find('## Tool: call_hash_', 1, true), 'matched results should not show call hashes')

-- Tool output is literal display data, even when it contains unclosed Markdown.
local output = table.concat({
  '# Heading inside output', '```lua', 'local value = 1', '```',
  '````', '   `````', '~~~', '<script>', '**unfinished emphasis', '[unfinished link',
}, '\n')
local tool_message = { role = 'tool', name = 'read_file', content = output }
ui.render({
  { role = 'user', content = '**User formatting**' }, tool_message,
  { role = 'tool', name = 'parts', content = { { type = 'text', text = 'part one' },
    { type = 'text', text = 'part two' } } },
  { role = 'assistant', content = '# After tool output\n**Assistant formatting**' },
}, 'Ready', 'openrouter', 'model-a', nil)
local safe_lines = vim.api.nvim_buf_get_lines(chat, 0, -1, false)
local safe_text = table.concat(safe_lines, '\n')
assert(safe_text:find('## Tool: read_file\n\n``````text\n' .. output .. '\n``````\n', 1, true),
  'outer fence must be longer than every backtick run in the tool output')
assert(safe_text:find('## Tool: parts\n\n```text\npart one\npart two\n```', 1, true),
  'text-part tool results should also be fenced')
assert(safe_text:find('## You\n**User formatting**', 1, true))
assert(safe_text:find('## Assistant\n# After tool output\n**Assistant formatting**', 1, true),
  'assistant Markdown should remain unfenced')
assert(tool_message.content == output, 'display fencing must not mutate the tool result')
vim.api.nvim_win_call(win, function()
  vim.cmd('syntax sync fromstart')
  local function syntax_at(text)
    for row, line in ipairs(safe_lines) do
      if line == text then return vim.fn.synIDattr(vim.fn.synID(row, 1, true), 'name') end
    end
    error('missing line ' .. text)
  end
  assert(syntax_at('# Heading inside output') == 'markdownCodeBlock', 'tool Markdown must stay literal')
  assert(syntax_at('   `````') == 'markdownCodeBlock', 'embedded fences must not close the wrapper')
  assert(syntax_at('**unfinished emphasis') == 'markdownCodeBlock')
  assert(syntax_at('# After tool output') == syntax_at('# Codeit (openrouter: model-a)'),
    'Markdown heading highlighting must recover after the tool block')
  assert(syntax_at('## Message') == syntax_at('## Assistant'), 'draft heading must remain outside code blocks')
end)
ui.close()
assert(#marks() == 0)
ui.open(function() sent = ui.take_input() end, ui.close)
assert(ui.is_open() and vim.fn.bufwinid(chat) ~= -1)
local last = vim.api.nvim_buf_line_count(chat)
vim.api.nvim_buf_set_lines(chat, last - 1, -1, false, { 'draft after reopen' })
ui.render(messages, 'Ready', 'copilot', 'model-b', nil)
assert(ui.take_input() == 'draft after reopen')
local fresh = vim.api.nvim_buf_line_count(chat)
vim.api.nvim_buf_set_lines(chat, fresh - 1, -1, false, { 'sent by mapping' })
vim.api.nvim_win_set_cursor(vim.fn.bufwinid(chat), { fresh, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'x', false)
assert(sent == 'sent by mapping', 'normal Enter sends the draft')

-- The interactive popup shares the sidebar buffer and all message mappings.
local function press(key, mode)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(chat, mode or 'n')) do
    if map.lhs:lower() == key:lower() then map.callback(); return end
  end
  error('missing mapping ' .. key)
end
local sidebar = vim.api.nvim_get_current_win()
local row = vim.api.nvim_buf_line_count(chat)
vim.api.nvim_buf_set_lines(chat, row - 1, -1, false, { 'popup draft' })
vim.api.nvim_win_set_cursor(sidebar, { row, 3 })
press('<C-g>')
local popup = vim.api.nvim_get_current_win()
assert(popup ~= sidebar and ui.is_open())
assert(vim.api.nvim_win_get_buf(popup) == chat and vim.bo[chat].modifiable)
assert(vim.api.nvim_win_get_config(popup).relative == 'editor')
assert(vim.api.nvim_win_get_width(popup) == vim.o.columns - 4)
assert(vim.api.nvim_win_get_height(popup) == vim.o.lines - 6)
assert(vim.api.nvim_win_get_config(popup).row == 1, 'extra padding belongs below the popup')
assert(vim.api.nvim_win_get_cursor(popup)[2] == 3 and ui.peek_input() == 'popup draft')
messages[#messages + 1] = { role = 'assistant', content = 'Live popup reply' }
ui.render(messages, 'Ready', 'copilot', 'model-b', nil)
assert(vim.api.nvim_get_current_win() == popup)
assert(vim.api.nvim_win_get_cursor(popup)[1] == vim.api.nvim_buf_line_count(chat))
assert(vim.api.nvim_win_get_cursor(popup)[2] == 3 and ui.peek_input() == 'popup draft')
assert(table.concat(vim.api.nvim_buf_get_lines(chat, 0, -1, false), '\n'):find('Live popup reply', 1, true))
press('<C-s>', 'i')
assert(sent == 'popup draft' and vim.api.nvim_get_current_win() == popup)
vim.api.nvim_buf_set_lines(chat, -1, -1, false, { 'return draft' })
press('<C-g>', 'i')
assert(not vim.api.nvim_win_is_valid(popup) and vim.api.nvim_get_current_win() == sidebar)
assert(ui.peek_input() == 'return draft' and ui.is_open())
press('<C-g>', 'i')
popup = vim.api.nvim_get_current_win()
press('<Esc>')
assert(not vim.api.nvim_win_is_valid(popup) and vim.api.nvim_get_current_win() == sidebar)
press('<C-g>')
popup = vim.api.nvim_get_current_win()
vim.api.nvim_win_close(popup, true)
assert(vim.wait(1000, function() return vim.api.nvim_get_current_win() == sidebar and ui.is_open() end))
press('<C-g>')
popup = vim.api.nvim_get_current_win()
press('q')
assert(not ui.is_open() and not vim.api.nvim_win_is_valid(popup) and not vim.api.nvim_win_is_valid(sidebar))
ui.open(function() sent = ui.take_input() end, ui.close)
assert(ui.peek_input() == 'return draft', 'closing the popup must preserve the draft')
sidebar = vim.api.nvim_get_current_win()
press('<C-g>')
popup = vim.api.nvim_get_current_win()
vim.api.nvim_win_close(sidebar, true)
assert(vim.wait(1000, function() return not ui.is_open() and not vim.api.nvim_win_is_valid(popup) end))
ui.open(function() sent = ui.take_input() end, ui.close)

vim.cmd('vsplit')
local unrelated = vim.api.nvim_get_current_win()
vim.cmd('close')
assert(not vim.api.nvim_win_is_valid(unrelated) and ui.is_open(), 'unrelated window closures must not close chat')
ui.close()
ui.open(function() end, ui.close)
local old_chat = vim.fn.bufwinid(chat)
vim.api.nvim_win_close(old_chat, true)
ui.open(function() end, ui.close) -- Reopen before the deferred WinClosed callback runs.
vim.wait(50, function() return false end)
assert(ui.is_open(), 'a stale window-close event must not close a reopened chat')
vim.cmd('close')
assert(vim.wait(1000, function() return not ui.is_open() end), 'manually closing the chat must reset the UI')
print('codeit ui tests passed')
