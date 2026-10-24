vim.opt.runtimepath:prepend(vim.fn.getcwd())
local ui = require('codeit.ui')
local api = vim.api
local original_tab = api.nvim_get_current_tabpage()
vim.cmd('tabnew')
local other_tab = api.nvim_get_current_tabpage()
api.nvim_set_current_tabpage(original_tab)
ui.open(function() end, ui.close)
local tab = api.nvim_get_current_tabpage()
local file_win = require('codeit.ui.managed_tab').windows()[1]
local sidebar = api.nvim_get_current_win()

local function return_to_popup(win)
  local cursor = api.nvim_win_get_cursor(win)
  -- Tab navigation may have selected a normal window while the popup stays open.
  api.nvim_set_current_win(file_win)
  api.nvim_set_current_tabpage(other_tab)
  local other_win = api.nvim_get_current_win()
  vim.wait(20)
  assert(api.nvim_get_current_win() == other_win, 'popups in another tab must not steal focus')
  vim.cmd('tabnext ' .. api.nvim_tabpage_get_number(tab))
  assert(api.nvim_get_current_win() == win, 'returning to a tab must focus its existing popup')
  assert(vim.deep_equal(api.nvim_win_get_cursor(win), cursor), 'restoring focus must preserve the cursor')
end

ui.toggle_popup()
local chat = api.nvim_get_current_win()
api.nvim_win_set_cursor(chat, { 1, 0 })
return_to_popup(chat)
ui.toggle_popup()
assert(api.nvim_get_current_win() == sidebar)

local prompt = require('codeit.tools.approval.prompt')
local calls = 0
local _, dismiss = prompt.show('Allow?', { { key = '1', id = 'once', label = 'Approve' } },
  function() calls = calls + 1 end)
local approval = api.nvim_get_current_win()
return_to_popup(approval)
local function press(win, key)
  for _, map in ipairs(api.nvim_buf_get_keymap(api.nvim_win_get_buf(win), 'n')) do
    if map.lhs:lower() == key:lower() then map.callback(); return end
  end
  error('missing mapping ' .. key)
end
press(approval, '<C-g>')
local preview = api.nvim_get_current_win()
return_to_popup(preview)
press(preview, '<Esc>')
assert(api.nvim_get_current_win() == approval and calls == 0)
dismiss()
vim.wait(20)
assert(calls == 1)

require('codeit.ui.input').show({ prompt = 'Answer?', default = 'draft' }, function() end)
local field = api.nvim_get_current_win()
vim.cmd('stopinsert')
-- Leaving Insert mode in a -l test can leave the cursor past the last character.
api.nvim_win_set_cursor(field, { 1, 2 })
return_to_popup(field)
assert(api.nvim_get_current_line() == 'draft')
press(field, '<Esc>')
vim.wait(20)

-- Ignore hidden, non-focusable and unrelated floats, even with a higher zindex.
local focus = require('codeit.ui.popup_focus')
local function floating(config, tracked)
  local win = api.nvim_open_win(api.nvim_create_buf(false, true), false,
    vim.tbl_extend('force', { relative = 'editor', row = 1, col = 1, width = 10, height = 2 }, config))
  if tracked then focus.track(win) end
  return win
end
ui.toggle_popup()
chat = api.nvim_get_current_win()
local hidden = floating({ hide = true, zindex = 100 }, true)
local passive = floating({ focusable = false, zindex = 100 }, true)
local unrelated = floating({ zindex = 100 }, false)
return_to_popup(chat)
for _, win in ipairs({ hidden, passive, unrelated }) do api.nvim_win_close(win, true) end
ui.toggle_popup()

-- Closed popups and ordinary sidebars must not redirect tab focus.
api.nvim_set_current_win(file_win)
api.nvim_set_current_tabpage(other_tab)
api.nvim_set_current_tabpage(tab)
assert(api.nvim_get_current_win() == file_win)
ui.close()
vim.cmd('qa!')
