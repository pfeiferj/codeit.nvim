vim.opt.runtimepath:prepend(vim.fn.getcwd())
local ui = require('codeit.ui')
local messages = {}
for i = 1, 50 do messages[i] = { role = 'user', content = 'message ' .. i } end
ui.open(function() end, function() end)
local chat = vim.fn.bufnr('codeit://chat')
local win = vim.fn.bufwinid(chat)
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
print('codeit ui tests passed')
