vim.opt.runtimepath:prepend(vim.fn.getcwd())
local ui = require('codeit.ui')
local messages = {}
for i = 1, 50 do messages[i] = { role = 'user', content = 'message ' .. i } end
ui.open(function() end, function() end)
local chat = vim.fn.bufnr('codeit://chat')
local win = vim.fn.bufwinid(chat)
local input = vim.fn.bufnr('codeit://input')
for _, buf in ipairs({ chat, input }) do
  assert(vim.bo[buf].filetype == 'markdown' and vim.bo[buf].syntax == 'markdown')
  assert(vim.b[buf].current_syntax == 'markdown', 'Markdown syntax should be loaded for both chat panes')
end
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
assert(rendered[4] == '## You')
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
ui.close()
assert(#marks() == 0)

local function pane_windows()
  return vim.fn.bufwinid(chat), vim.fn.bufwinid(input)
end

for _, pane in ipairs({ 'chat', 'input' }) do
  ui.open(function() end, ui.close)
  local chat_win, input_win = pane_windows()
  assert(ui.is_open())
  vim.api.nvim_set_current_win(pane == 'chat' and chat_win or input_win)
  vim.cmd('close')
  local other = pane == 'chat' and input_win or chat_win
  assert(vim.wait(1000, function() return not vim.api.nvim_win_is_valid(other) end),
    'closing ' .. pane .. ' must close the other pane')
  assert(not ui.is_open())
end

ui.open(function() end, ui.close)
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
ui.close()
print('codeit ui tests passed')
