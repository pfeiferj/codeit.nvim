vim.opt.runtimepath:prepend(vim.fn.getcwd())
local prompt = require('codeit.approval_prompt')
local options = {
  { key = '1', id = 'once', label = 'Approve once' },
  { key = '2', id = 'tracked', label = 'Trust workspace (Git-tracked reads)' },
}
local function open_and_press(key, expected, config, option_line)
  local result, calls
  calls = 0
  local previous = vim.api.nvim_get_current_win()
  prompt.show('Read file?\nReason', options, function(choice)
    calls = calls + 1
    result = choice or 'rejected'
  end, config)
  local win = vim.api.nvim_get_current_win()
  local win_config = vim.api.nvim_win_get_config(win)
  assert(win_config.width >= math.floor(vim.o.columns * 0.8) and win_config.height >= math.floor(vim.o.lines * 0.75),
    'decision window should fill most of the editor')
  local buf = vim.api.nvim_win_get_buf(win)
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
  assert(text:find('Read file?', 1, true) and text:find('Reason', 1, true))
  assert(text:find('**[2]** Trust workspace', 1, true))
  assert(text:find('**[Esc]** ' .. (config and config.dismiss or 'Reject'), 1, true))
  assert(vim.bo[buf].filetype == 'markdown' and vim.bo[buf].syntax == 'markdown')
  assert(vim.b[buf].current_syntax == 'markdown')
  vim.api.nvim_win_call(win, function()
    assert(vim.fn.synIDattr(vim.fn.synID(1, 1, true), 'name') ~= '',
      'approval heading should have active Markdown highlighting')
  end)
  local cursor = vim.api.nvim_win_get_cursor(win)
  local first_choice = cursor[1]
  assert(vim.api.nvim_buf_get_lines(buf, first_choice - 1, first_choice, false)[1] == '- **[1]** Approve once',
    'choice cursor must start on the first option')
  if option_line then vim.api.nvim_win_set_cursor(win, { first_choice + option_line - 1, 0 }) end
  local map
  for _, item in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
    if item.lhs == key then map = item; break end
  end
  assert(map and map.callback, 'missing hotkey ' .. key)
  map.callback()
  assert(result == expected and calls == 1)
  assert(not vim.api.nvim_win_is_valid(win))
  assert(vim.api.nvim_get_current_win() == previous)
  vim.wait(20)
  assert(calls == 1, 'WinClosed must not decide twice')
end
open_and_press('1', 'once')
open_and_press('2', 'tracked')
open_and_press('<CR>', 'once')
open_and_press('<CR>', 'tracked', nil, 2)
open_and_press('1', 'once', nil, 2) -- numeric shortcuts work regardless of cursor position
open_and_press('<Esc>', 'rejected')
open_and_press('<CR>', 'tracked', { title = ' Tool-call reviewer ', dismiss = 'Back to approval' }, 2)
open_and_press('<Esc>', 'rejected', { title = ' Tool-call reviewer ', dismiss = 'Back to approval' })
local ignored_calls = 0
prompt.show('Read file?', options, function() ignored_calls = ignored_calls + 1 end)
local ignored_win = vim.api.nvim_get_current_win()
local ignored_buf = vim.api.nvim_win_get_buf(ignored_win)
local enter
for _, item in ipairs(vim.api.nvim_buf_get_keymap(ignored_buf, 'n')) do
  if item.lhs == '<CR>' then enter = item.callback; break end
end
assert(enter, 'missing Enter mapping')
local first_choice = vim.api.nvim_win_get_cursor(ignored_win)[1]
for _, line in ipairs({ 1, first_choice - 1, first_choice + #options, first_choice + #options + 1 }) do
  vim.api.nvim_win_set_cursor(ignored_win, { line, 0 })
  enter()
  assert(ignored_calls == 0 and vim.api.nvim_win_is_valid(ignored_win),
    'Enter outside an option must not select anything')
end
vim.api.nvim_win_close(ignored_win, true)
assert(vim.wait(1000, function() return ignored_calls == 1 end))
local closed = 0
prompt.show('Read file?', options, function(choice)
  assert(choice == nil)
  closed = closed + 1
end)
vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)
assert(vim.wait(1000, function() return closed == 1 end), 'closing the window should reject')

local function mapping(buf, key, mode)
  for _, item in ipairs(vim.api.nvim_buf_get_keymap(buf, mode or 'n')) do
    if item.lhs == key then return item.callback end
  end
  error('missing reviewer key ' .. key)
end
local previous = vim.api.nvim_get_current_win()
local questions, replies, backs = {}, {}, 0
prompt.ask_reviewer('run_command', '{"argv":["echo","hello"]}', function(question, reply)
  questions[#questions + 1] = question
  replies[#replies + 1] = reply
end, function() backs = backs + 1 end)
local input_win = vim.api.nvim_get_current_win()
local input_buf = vim.api.nvim_win_get_buf(input_win)
local transcript_win = assert(vim.iter(vim.api.nvim_list_wins()):find(function(win)
  return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), '\n')
    :find('# Review tool call', 1, true) ~= nil
end))
local transcript_buf = vim.api.nvim_win_get_buf(transcript_win)
local config = vim.api.nvim_win_get_config(transcript_win)
assert(config.width >= math.floor(vim.o.columns * 0.8))
assert(vim.api.nvim_win_get_config(input_win).height > 0)
local function transcript()
  return table.concat(vim.api.nvim_buf_get_lines(transcript_buf, 0, -1, false), '\n')
end
assert(transcript():find('**Tool:** `run_command`', 1, true) and transcript():find('```json', 1, true))
assert(transcript():find('normal-mode <Enter> to send', 1, true), transcript())
assert(vim.bo[transcript_buf].modifiable == false and vim.bo[input_buf].modifiable)
assert(vim.bo[transcript_buf].filetype == 'markdown' and vim.b[transcript_buf].current_syntax == 'markdown')
local send = mapping(input_buf, '<CR>')
send()
assert(#questions == 0, 'empty questions must not be sent')
vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { 'Is it safe?', 'Any side effects?' })
send()
assert(questions[1] == 'Is it safe?\nAny side effects?' and #questions == 1)
assert(vim.api.nvim_win_is_valid(input_win) and vim.api.nvim_win_is_valid(transcript_win))
assert(transcript():find('## You\nIs it safe?\nAny side effects?\n\n*Waiting for reviewer…*', 1, true))
assert(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)[1] == '')
vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { 'Follow up' })
send()
assert(#questions == 1, 'do not submit while a response is pending')
replies[1]('This only prints text')
assert(transcript():find('## Reviewer\nThis only prints text', 1, true))
assert(not transcript():find('Waiting for reviewer', 1, true))
send()
assert(questions[2] == 'Follow up' and #questions == 2)
replies[2]('Another answer')
assert(transcript():find('## You\nFollow up', 1, true) and transcript():find('Another answer', 1, true))
assert(mapping(input_buf, '<C-S>', 'i'), 'insert-mode Ctrl-S should send')
mapping(input_buf, '<Esc>')()
assert(backs == 1 and not vim.api.nvim_win_is_valid(input_win) and not vim.api.nvim_win_is_valid(transcript_win))
assert(vim.api.nvim_get_current_win() == previous)
vim.wait(20)
assert(backs == 1, 'WinClosed must not return to approval twice')
prompt.ask_reviewer('read_file', '{"path":"secret"}\n{"extra":"```"}', function(_, reply)
  replies[#replies + 1] = reply
end, function() backs = backs + 1 end)
local pending_input = vim.api.nvim_get_current_win()
local pending_buf = vim.api.nvim_win_get_buf(pending_input)
local pending_transcript = assert(vim.iter(vim.api.nvim_list_wins()):find(function(win)
  return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), '\n')
    :find('# Review tool call', 1, true) ~= nil
end))
local pending_text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(pending_transcript), 0, -1, false), '\n')
assert(pending_text:find('````json', 1, true))
vim.api.nvim_buf_set_lines(pending_buf, 0, -1, false, { 'Pending question' })
mapping(pending_buf, '<CR>')()
vim.api.nvim_win_close(pending_transcript, true)
assert(vim.wait(1000, function() return backs == 2 end))
assert(not vim.api.nvim_win_is_valid(pending_input), 'closing either pane should close the reviewer')
replies[3]('Late answer') -- A stale response must not reopen the reviewer.
assert(backs == 2)
print('codeit approval prompt tests passed')
