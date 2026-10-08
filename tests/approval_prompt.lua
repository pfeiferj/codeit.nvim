vim.opt.runtimepath:prepend(vim.fn.getcwd())
local prompt = require('codeit.approval_prompt')
local options = {
  { key = '1', id = 'once', label = 'Approve once' },
  { key = '2', id = 'tracked', label = 'Trust workspace (Git-tracked reads)' },
}
local function open_and_press(key, expected, config)
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
  assert(text:find('[2] Trust workspace', 1, true))
  assert(text:find('[Esc] ' .. (config and config.dismiss or 'Reject'), 1, true))
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
open_and_press('<Esc>', 'rejected')
open_and_press('<Esc>', 'rejected', { title = ' Tool-call reviewer ', dismiss = 'Back to approval' })
local closed = 0
prompt.show('Read file?', options, function(choice)
  assert(choice == nil)
  closed = closed + 1
end)
vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)
assert(vim.wait(1000, function() return closed == 1 end), 'closing the window should reject')

local function ask_and_press(key, question, expected)
  local previous = vim.api.nvim_get_current_win()
  local calls, result = 0, nil
  prompt.ask_reviewer('run_command', '{"argv":["echo","hello"]}', function(value)
    calls = calls + 1
    result = value
  end)
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  local config = vim.api.nvim_win_get_config(win)
  assert(config.width >= math.floor(vim.o.columns * 0.8) and config.height >= math.floor(vim.o.lines * 0.75))
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
  assert(text:find('Tool: run_command', 1, true) and text:find('echo', 1, true))
  assert(text:find('normal-mode <Enter> to send', 1, true), 'reviewer prompt should advertise Enter')
  assert(vim.api.nvim_win_get_cursor(win)[1] == vim.api.nvim_buf_line_count(buf))
  if question then vim.api.nvim_buf_set_lines(buf, -1, -1, false, vim.split(question, '\n', { plain = true })) end
  local map
  for _, item in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
    if item.lhs == key then map = item; break end
  end
  assert(map and map.callback, 'missing reviewer key ' .. key)
  map.callback()
  assert(calls == 1 and result == expected)
  assert(not vim.api.nvim_win_is_valid(win) and vim.api.nvim_get_current_win() == previous)
  vim.wait(20)
  assert(calls == 1)
end
ask_and_press('<C-S>', 'Is it safe?\nAny side effects?', 'Is it safe?\nAny side effects?')
ask_and_press('<CR>', 'What does this tool do?', 'What does this tool do?')
ask_and_press('<CR>', '  ', '')
ask_and_press('<Esc>', 'Never sent', nil)
local dismissed = 0
prompt.ask_reviewer('read_file', '{"path":"secret"}', function(value)
  assert(value == nil)
  dismissed = dismissed + 1
end)
vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)
assert(vim.wait(1000, function() return dismissed == 1 end))
print('codeit approval prompt tests passed')
