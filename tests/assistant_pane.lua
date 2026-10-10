vim.opt.runtimepath:prepend(vim.fn.getcwd())
local pane = require('codeit.assistant_pane')
local ui = require('codeit.ui')
local prompt = require('codeit.approval_prompt')
local original = vim.api.nvim_get_current_win()
local function explanation_win(except)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if win ~= original and win ~= except then return win end
  end
end
local function press(win, key)
  local buf = vim.api.nvim_win_get_buf(win)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
    if map.lhs == key then map.callback(); return end
  end
  error('missing mapping ' .. key)
end
ui.render({ { role = 'user', content = 'Fix it' },
  { role = 'assistant', content = { { type = 'text', text = '**I will inspect first.**' } } },
  { role = 'tool', content = 'output' }, { role = 'assistant', content = vim.NIL } }, '', 'test', 'test')
local calls = 0
prompt.show('Allow?', { { key = '1', id = 'once', label = 'Approve' } }, function() calls = calls + 1 end)
local win = vim.api.nvim_get_current_win()
local above = assert(explanation_win(win))
local config, top = vim.api.nvim_win_get_config(win), vim.api.nvim_win_get_config(above)
assert(top.row + top.height + 2 <= config.row, 'pane must be above the popup')
local buf = vim.api.nvim_win_get_buf(above)
assert(vim.bo[buf].filetype == 'codeit' and not vim.bo[buf].modifiable)
assert(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == '**I will inspect first.**')
assert(vim.api.nvim_get_current_win() == win, 'explanation must not take focus')
press(win, '1')
assert(calls == 1 and not vim.api.nvim_win_is_valid(above))
assert(vim.api.nvim_get_current_win() == original)
vim.wait(20)
assert(calls == 1)

local close = pane.question()
local fallback = assert(explanation_win())
assert(vim.api.nvim_win_get_config(fallback).row == 0, 'command-line questions need a pane at the top')
local question_buf = vim.api.nvim_create_buf(false, true)
vim.bo[question_buf].bufhidden = 'wipe'
local question = vim.api.nvim_open_win(question_buf, true, {
  relative = 'editor', row = 4, col = 4, width = 30, height = 3, border = 'rounded', style = 'minimal',
})
vim.wait(50)
above = assert(explanation_win(question))
config, top = vim.api.nvim_win_get_config(question), vim.api.nvim_win_get_config(above)
assert(top.row + top.height + 2 <= config.row)
assert(vim.api.nvim_get_current_win() == question)
vim.api.nvim_win_close(question, true)
close()
close()
assert(#vim.api.nvim_list_wins() == 1, 'question cleanup must remove the pane')

local write = require('codeit.write_approval')
write.show({ before = 'old\n', after = 'new\n', path = 'example.lua' },
  { { key = '1', id = 'once', label = 'Approve' } }, function() end)
win = vim.api.nvim_get_current_win()
above = assert(explanation_win(win))
vim.api.nvim_win_close(win, true)
assert(vim.wait(1000, function() return not vim.api.nvim_win_is_valid(above) end))

pane.set_messages({ { role = 'assistant', content = 'Old explanation' }, { role = 'user', content = 'New task' } })
local frame = { width = 30, height = 10, row = 1, col = 1 }
close = pane.open(frame)
assert(#vim.api.nvim_list_wins() == 1 and frame.height == 10, 'new user turn must clear stale explanations')
close()
pane.set_messages({ { role = 'assistant', content = string.rep('long line ', 1000) } })
frame = { width = 30, height = 100, row = 1, col = 1 }
close = pane.open(frame)
assert(frame.row + frame.height + 2 <= vim.o.lines, 'long explanations must leave room for the popup')
close()
local old_lines = vim.o.lines
vim.o.lines = 8
close = pane.open({ width = 30, height = 1, row = 0, col = 0 })
assert(#vim.api.nvim_list_wins() == 1, 'tiny editors must omit the pane')
close()
vim.o.lines = old_lines
pane.set_messages({})
vim.cmd('qa!')
