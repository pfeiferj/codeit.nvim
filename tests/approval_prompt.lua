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
  prompt.show('# read_file\n\nRead file?\nReason', options, function(choice)
    calls = calls + 1
    result = choice or 'rejected'
  end, config)
  local win = vim.api.nvim_get_current_win()
  local win_config = vim.api.nvim_win_get_config(win)
  assert(win_config.width == vim.o.columns - 4 and win_config.height == vim.o.lines - 6,
    'decision window should leave only a small fixed margin')
  local buf = vim.api.nvim_win_get_buf(win)
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
  assert(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == '# read_file',
    'tool name must be the only top-level Markdown heading')
  assert(not text:find('# Approve tool call', 1, true), 'approval heading should not be duplicated')
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
local updated_choice
local update = prompt.show('# run_command\n\nRun command?\n\nSummary: Waiting for provider…', options,
  function(choice) updated_choice = choice end)
local updated_win = vim.api.nvim_get_current_win()
local updated_buf = vim.api.nvim_win_get_buf(updated_win)
local choice_row = vim.api.nvim_win_get_cursor(updated_win)[1]
update('# run_command\n\nRun command?\n\n**Summary: Potentially unsafe.**')
assert(vim.api.nvim_buf_get_lines(updated_buf, 0, 1, false)[1] == '# run_command')
assert(vim.api.nvim_get_current_win() == updated_win)
assert(vim.api.nvim_win_get_cursor(updated_win)[1] == choice_row)
assert(table.concat(vim.api.nvim_buf_get_lines(updated_buf, 0, -1, false), '\n')
  :find('**Summary: Potentially unsafe.**', 1, true))
for _, item in ipairs(vim.api.nvim_buf_get_keymap(updated_buf, 'n')) do
  if item.lhs == '1' then item.callback(); break end
end
assert(updated_choice == 'once')
update('Late response') -- closed prompts must ignore delayed updates
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
local reviewer_win = vim.api.nvim_get_current_win()
local reviewer_buf = vim.api.nvim_win_get_buf(reviewer_win)
local config = vim.api.nvim_win_get_config(reviewer_win)
assert(config.width >= math.floor(vim.o.columns * 0.8) and config.height >= math.floor(vim.o.lines * 0.75))
assert(#vim.api.nvim_list_wins() == 2, 'reviewer must use only one popup window')
local function transcript()
  return table.concat(vim.api.nvim_buf_get_lines(reviewer_buf, 0, -1, false), '\n')
end
local function draft_line()
  return vim.api.nvim_buf_line_count(reviewer_buf)
end
local function assert_question_footer()
  assert(vim.deep_equal(vim.api.nvim_buf_get_lines(reviewer_buf, -4, -1, false), { '## Question', '', '' }),
    'question heading should have an empty line before the draft')
end
assert(transcript():find('**Tool:** `run_command`', 1, true) and transcript():find('```json', 1, true))
assert(transcript():find('normal-mode <Enter> to send', 1, true), transcript())
assert(vim.bo[reviewer_buf].modifiable and vim.bo[reviewer_buf].filetype == 'markdown')
assert(vim.b[reviewer_buf].current_syntax == 'markdown')
assert_question_footer()
assert(vim.api.nvim_win_get_cursor(reviewer_win)[1] == draft_line(), 'focus should start on the draft')
local send = mapping(reviewer_buf, '<CR>')
send()
assert(#questions == 0, 'empty questions must not be sent')
vim.api.nvim_buf_set_lines(reviewer_buf, -2, -1, false, { 'Is it safe?', 'Any side effects?' })
send()
assert(questions[1] == 'Is it safe?\nAny side effects?' and #questions == 1)
assert(vim.api.nvim_win_is_valid(reviewer_win))
assert(transcript():find('## You\nIs it safe?\nAny side effects?\n\n*Waiting for reviewer…*', 1, true))
assert_question_footer()
assert(vim.api.nvim_win_get_cursor(reviewer_win)[1] == draft_line(), 'sending should focus the draft')
vim.api.nvim_buf_set_lines(reviewer_buf, -2, -1, false, { 'Follow up' })
vim.api.nvim_win_set_cursor(reviewer_win, { draft_line(), 4 })
send()
assert(#questions == 1, 'do not submit while a response is pending')
replies[1]('This only prints text')
assert(transcript():find('## Reviewer\nThis only prints text', 1, true))
assert(not transcript():find('Waiting for reviewer', 1, true))
assert(vim.api.nvim_buf_get_lines(reviewer_buf, -2, -1, false)[1] == 'Follow up')
assert(vim.deep_equal(vim.api.nvim_win_get_cursor(reviewer_win), { draft_line(), 4 }),
  'reply must preserve draft cursor')
send()
assert(questions[2] == 'Follow up' and #questions == 2)
replies[2]('Another answer')
assert(transcript():find('## You\nFollow up', 1, true) and transcript():find('Another answer', 1, true))
assert_question_footer()
assert(mapping(reviewer_buf, '<C-S>', 'i'), 'insert-mode Ctrl-S should send')
mapping(reviewer_buf, '<Esc>')()
assert(backs == 1 and not vim.api.nvim_win_is_valid(reviewer_win))
assert(vim.api.nvim_get_current_win() == previous)
vim.wait(20)
assert(backs == 1, 'WinClosed must not return to approval twice')
prompt.ask_reviewer('read_file', '{"path":"secret"}\n{"extra":"```"}', function(_, reply)
  replies[#replies + 1] = reply
end, function() backs = backs + 1 end)
local pending_win = vim.api.nvim_get_current_win()
local pending_buf = vim.api.nvim_win_get_buf(pending_win)
local pending_text = table.concat(vim.api.nvim_buf_get_lines(pending_buf, 0, -1, false), '\n')
assert(pending_text:find('````json', 1, true))
vim.api.nvim_buf_set_lines(pending_buf, -2, -1, false, { 'Pending question' })
mapping(pending_buf, '<CR>')()
vim.api.nvim_win_close(pending_win, true)
assert(vim.wait(1000, function() return backs == 2 end))
replies[3]('Late answer') -- A stale response must not reopen the reviewer.
assert(backs == 2 and vim.api.nvim_get_current_win() == previous)
-- Tool-limit decisions use the same keyboard-driven popup, with safe dismissal.
local limit_prompt = require('codeit.tool_limit_prompt')
local function limit_choice(key, expected, default_rounds)
  local result, calls = false, 0
  limit_prompt.show(default_rounds or 12, function() return true end, function(rounds)
    result, calls = rounds, calls + 1
  end)
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
  assert(text:find('Tool limit reached', 1, true) and text:find('Individual tool approvals still apply', 1, true))
  assert(text:find('**[Esc]** Decline additional tools', 1, true))
  if key == 'close' then vim.api.nvim_win_close(win, true) else mapping(buf, key)() end
  assert(vim.wait(1000, function() return calls == 1 end))
  assert(result == expected and not vim.api.nvim_win_is_valid(win))
  vim.wait(20)
  assert(calls == 1, 'closing the limit popup must not decide twice')
end
limit_choice('1', 12)
limit_choice('<CR>', 12)
limit_choice('3', nil)
limit_choice('<Esc>', nil)
limit_choice('close', nil)
vim.ui.input = function(opts, cb)
  assert(opts.default == '12')
  cb('3')
end
limit_choice('2', 3)
print('codeit approval prompt tests passed')
