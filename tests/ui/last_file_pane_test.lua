vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.hidden = true
vim.o.columns = 160
local layout = require('codeit.ui.managed_tab')
local ui = require('codeit.ui')
local original_tab = vim.api.nvim_get_current_tabpage()
local original_win = vim.api.nvim_get_current_win()
local source = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(source, 0, -1, false, { 'unsaved user text' })
ui.open(function() end, ui.close)
local tab = layout.tab()
local chat = vim.fn.bufwinid('codeit://chat')
local win = layout.windows()[1]

local function blank_after_close(command)
  local row, col = unpack(vim.api.nvim_win_get_position(win))
  local width, height = vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win)
  vim.api.nvim_set_current_win(win)
  vim.cmd(command)
  assert(vim.wait(1000, function() return #layout.windows() == 1 end), command .. ': missing file pane')
  win = layout.windows()[1]
  local id = layout.buffer(win)
  assert(vim.api.nvim_get_current_win() == win)
  assert(layout.tab() == tab and vim.api.nvim_win_is_valid(chat))
  assert(vim.api.nvim_buf_get_name(id) == '' and vim.bo[id].buftype == '' and vim.bo[id].buflisted)
  assert(not vim.bo[id].modified and vim.api.nvim_buf_get_lines(id, 0, -1, false)[1] == '')
  local new_row, new_col = unpack(vim.api.nvim_win_get_position(win))
  assert(new_row == row and new_col == col, command .. ': pane moved')
  assert(vim.api.nvim_win_get_width(win) == width and vim.api.nvim_win_get_height(win) == height,
    command .. ': pane resized')
  assert(vim.bo[source].modified and vim.api.nvim_buf_get_lines(source, 0, -1, false)[1] == 'unsaved user text')
  assert(vim.api.nvim_win_get_buf(original_win) == source)
end

blank_after_close('close')
blank_after_close('quit')
blank_after_close('wincmd c')

-- Only the last file pane is replaced; additional splits close normally.
local split = layout.split(win, 'horizontal')
vim.api.nvim_set_current_win(split)
vim.cmd('close')
vim.wait(20, function() return false end)
assert(not vim.api.nvim_win_is_valid(split) and #layout.windows() == 1)
assert(layout.windows()[1] == win)

-- Restore the pane on the other side of chat, too.
vim.api.nvim_set_current_win(win)
vim.cmd('wincmd L')
blank_after_close('close')
vim.api.nvim_set_current_win(win)
vim.cmd('wincmd K')
blank_after_close('close')

-- Explicitly closing the tab must not restore any file pane.
vim.cmd('tabclose!')
vim.wait(20, function() return false end)
assert(not vim.api.nvim_tabpage_is_valid(tab) and not layout.tab())
assert(vim.api.nvim_get_current_tabpage() == original_tab)
assert(#vim.api.nvim_tabpage_list_wins(original_tab) == 1)
print('codeit last file pane tests passed')
