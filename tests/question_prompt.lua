vim.opt.runtimepath:prepend(vim.fn.getcwd())
local prompt = require('codeit.question_prompt')
local original = vim.api.nvim_get_current_win()
local function press(key, mode)
  local buf = vim.api.nvim_get_current_buf()
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, mode or 'n')) do
    if map.lhs:lower() == key:lower() then map.callback(); return end
  end
  error('missing mapping ' .. key)
end
local function text()
  return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
end
local calls, answer = 0, nil
local function reply(value) calls = calls + 1; answer = value end
local question = '# Choose an approach\n\nFirst option or second?'
prompt.show(question, nil, reply)
local win = vim.api.nvim_get_current_win()
local config = vim.api.nvim_win_get_config(win)
assert(config.relative == 'editor' and config.width == vim.o.columns - 4)
assert(config.height == vim.o.lines - 6)
assert(text():find(question, 1, true) and vim.bo.filetype == 'markdown')
press('<CR>')
assert(calls == 0, 'empty answers should not submit')
local row = vim.api.nvim_win_get_cursor(win)[1]
vim.api.nvim_buf_set_lines(0, row - 1, -1, false, { 'Use the first option.', 'Keep it simple.' })
press('<C-S>', 'i')
assert(answer == 'Use the first option.\nKeep it simple.' and calls == 1)
assert(not vim.api.nvim_win_is_valid(win) and vim.api.nvim_get_current_win() == original)
vim.wait(20)
assert(calls == 1, 'closing after submission must not cancel again')

prompt.show(question, { 'First', 'Second' }, reply)
assert(text():find(question, 1, true))
press('2')
assert(answer == 'Second' and calls == 2)
prompt.show(question, { 'First' }, reply)
press('o')
assert(text():find(question, 1, true) and text():find('## Answer', 1, true))
row = vim.api.nvim_win_get_cursor(0)[1]
vim.api.nvim_buf_set_lines(0, row - 1, -1, false, { 'Custom answer' })
press('<CR>')
assert(answer == 'Custom answer' and calls == 3)

local choices = {}
for i = 1, 10 do choices[i] = 'Option ' .. i end
prompt.show(question, choices, reply)
press('0')
assert(answer == 'Option 10' and calls == 4)
for _, options in ipairs({ {}, { 'First' } }) do
  prompt.show(question, options, reply)
  press('<Esc>')
  assert(answer == nil)
end
assert(calls == 6)
prompt.show(question, nil, reply)
vim.api.nvim_win_close(0, true)
assert(vim.wait(1000, function() return calls == 7 end))
assert(answer == nil and #vim.api.nvim_list_wins() == 1)
print('codeit question popup tests passed')
vim.cmd('qa!')
