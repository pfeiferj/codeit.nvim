vim.opt.runtimepath:prepend(vim.fn.getcwd())
local ui = require('codeit.ui')
local prompt = require('codeit.approval_prompt')
local write = require('codeit.write_approval')
local function press(win, key, mode)
  vim.api.nvim_set_current_win(win)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(vim.api.nvim_win_get_buf(win), mode or 'n')) do
    if map.lhs:lower() == key:lower() then map.callback(); return end
  end
  error('missing mapping ' .. key)
end
local messages = { { role = 'user', content = 'Earlier request' },
  { role = 'assistant', content = 'Earlier explanation' },
  { role = 'tool', content = table.concat({ 'Tool output', 'two', 'three', 'four', 'five', 'six', 'seven' }, '\n'),
    name = 'read_file' },
  { role = 'tool', content = 'Wrapped output ' .. string.rep('wide 界\t', 200), name = 'read_file' },
  { role = 'user', content = 'Current request' } }
ui.render(messages, '', 'test', 'test', nil,
  { { after_message = 0, command = 'CodeitTrustStatus', output = 'Trust result' } })
local options = { { key = '1', id = 'once', label = 'Approve' } }
local calls = 0
local update = prompt.show('Allow?', options, function(choice)
  calls = calls + 1
  assert(choice == 'once')
end)
local win = vim.api.nvim_get_current_win()
local cursor = vim.api.nvim_win_get_cursor(win)
press(win, '<C-g>')
local chat = vim.api.nvim_get_current_win()
local chat_buf = vim.api.nvim_win_get_buf(chat)
assert(chat ~= win and vim.api.nvim_win_is_valid(win) and calls == 0)
assert(not vim.bo[chat_buf].modifiable and vim.bo[chat_buf].filetype == 'codeit')
local text = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), '\n')
for _, expected in ipairs({ 'Earlier request', 'Earlier explanation', 'Tool output', 'Current request', 'Trust result' }) do
  assert(text:find(expected, 1, true), expected)
end
assert(not text:find('## Message', 1, true))
local turns = {}
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(chat_buf,
  vim.api.nvim_get_namespaces().codeit_chat_ui, 0, -1, { details = true })) do
  if mark[4].hl_group == 'CodeitUser' then turns[#turns + 1] = mark[2] + 1 end
end
vim.api.nvim_win_set_cursor(chat, { 1, 0 })
press(chat, '}')
assert(vim.api.nvim_win_get_cursor(chat)[1] == turns[1])
press(chat, '}')
assert(vim.api.nvim_win_get_cursor(chat)[1] == turns[2], 'read-only preview should skip assistant and tools')
press(chat, '{')
assert(vim.api.nvim_win_get_cursor(chat)[1] == turns[1])
assert(vim.wo[chat].linebreak and vim.wo[chat].foldmethod == 'manual')
local tool_row
for row, line in ipairs(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false)) do
  if line == '```text' then tool_row = row; break end
end
assert(tool_row and vim.fn.foldclosed(tool_row) == tool_row, 'read-only previews should fold long tool results')
for row, line in ipairs(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false)) do
  if line:find('Wrapped output ', 1, true) == 1 then
    assert(vim.fn.foldclosed(row) == row - 1, 'read-only previews should fold wrapped single-line output')
  end
end
assert(vim.fn.foldtextresult(tool_row):find('Tool output', 1, true))
vim.api.nvim_win_set_cursor(chat, { tool_row, 0 })
vim.cmd('normal! za')
assert(vim.fn.foldclosed(tool_row) == -1 and not vim.bo[chat_buf].modifiable,
  'read-only tool results should expand without making the transcript editable')
for _, map in ipairs(vim.api.nvim_buf_get_keymap(chat_buf, 'n')) do
  assert(map.lhs ~= '1' and map.lhs ~= '<CR>', 'preview must not inherit approval mappings')
end
vim.api.nvim_win_set_cursor(chat, { 2, 0 })
update('Updated approval')
press(chat, '<Esc>')
assert(vim.api.nvim_get_current_win() == win and calls == 0)
assert(vim.deep_equal(vim.api.nvim_win_get_cursor(win), cursor))
messages[#messages + 1] = { role = 'user', content = 'Latest update' }
ui.render(messages, '', 'test', 'test')
press(win, '<C-g>')
chat = vim.api.nvim_get_current_win()
assert(vim.api.nvim_win_get_cursor(chat)[1] == 2, 'remember preview position')
text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(chat), 0, -1, false), '\n')
assert(text:find('Latest update', 1, true))
press(chat, '<C-g>')
press(win, '1')
assert(calls == 1)
vim.wait(20)
assert(calls == 1 and #vim.api.nvim_list_wins() == 1)

-- A sidebar draft is not exposed or mutated by the preview.
ui.open(function() error('must not send') end, ui.close)
ui.render(messages, '', 'test', 'test')
local sidebar_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(sidebar_buf, -1, -1, false, { 'Unsent secret draft' })
ui.close()
local backs = 0
prompt.ask_reviewer('run_command', '{}', function() end, function() backs = backs + 1 end)
win = vim.api.nvim_get_current_win()
local reviewer_buf = vim.api.nvim_win_get_buf(win)
vim.api.nvim_buf_set_lines(reviewer_buf, -2, -1, false, { 'Reviewer draft' })
cursor = vim.api.nvim_win_get_cursor(win)
press(win, '<C-g>', 'i')
chat = vim.api.nvim_get_current_win()
text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(chat), 0, -1, false), '\n')
assert(not text:find('Unsent secret draft', 1, true))
press(chat, 'q')
assert(vim.deep_equal(vim.api.nvim_win_get_cursor(win), cursor))
assert(vim.api.nvim_buf_get_lines(reviewer_buf, -2, -1, false)[1] == 'Reviewer draft')
assert(backs == 0)
press(win, '<Esc>')
assert(backs == 1)

local rejected = 0
write.show({ before = 'old\n', after = 'new\n', path = 'example.lua' }, options,
  function(choice) assert(choice == nil); rejected = rejected + 1 end)
win = vim.api.nvim_get_current_win()
cursor = vim.api.nvim_win_get_cursor(win)
press(win, '<C-g>')
chat = vim.api.nvim_get_current_win()
press(chat, '<Esc>')
assert(rejected == 0 and vim.deep_equal(vim.api.nvim_win_get_cursor(win), cursor))
press(win, '<C-g>')
chat = vim.api.nvim_get_current_win()
vim.api.nvim_win_close(win, true)
assert(vim.wait(1000, function() return rejected == 1 and not vim.api.nvim_win_is_valid(chat) end))
assert(#vim.api.nvim_list_wins() == 1, 'closing underlying popup must clean up preview')
vim.cmd('qa!')
