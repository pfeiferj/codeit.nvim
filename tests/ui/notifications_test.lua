vim.opt.runtimepath:prepend(vim.fn.getcwd())
local original_notify, defer = vim.notify, vim.defer_fn
local forwarded, timers = {}, {}
vim.notify = function(...) forwarded[#forwarded + 1] = { ... }; return 'forwarded' end
vim.defer_fn = function(callback, delay) timers[#timers + 1] = { callback = callback, delay = delay } end
local popup = require('codeit.ui.notifications')
popup.install()
local routed_notify = vim.notify
popup.install()
assert(vim.notify == routed_notify, 'installation must be idempotent')
local function window()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.b[vim.api.nvim_win_get_buf(win)].codeit_notification then return win end
  end
end
local function contents()
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(assert(window())), 0, -1, false)
end
local origin, tab = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_tabpage()
assert(vim.notify('other plugin', vim.log.levels.WARN, { title = 'Other' }) == 'forwarded')
assert(#forwarded == 1 and not window())
vim.notify('codeit: first', vim.log.levels.ERROR)
local win = assert(window())
local buf = vim.api.nvim_win_get_buf(win)
local config = vim.api.nvim_win_get_config(win)
assert(vim.api.nvim_get_current_win() == origin and not config.focusable)
assert(config.relative == 'editor' and config.anchor == 'NE' and config.row == 0)
assert(config.col == vim.o.columns - 1 and config.zindex > 200)
assert(#config.border == 8 and config.border[1] == '╭')
assert(not vim.bo[buf].modifiable and not vim.wo[win].wrap)
assert(vim.deep_equal(contents(), { '[ERROR] first' }))
assert(timers[1].delay == 4000)
vim.notify('Approval required', vim.log.levels.INFO, { title = 'Codeit' })
vim.notify('codeit: third\nmore', vim.log.levels.WARN)
assert(window() == win and #timers == 3 and #forwarded == 1)
assert(vim.deep_equal(contents(), { '[ERROR] first', '', '[INFO] Approval required', '', '[WARN] third', 'more' }))
local marks = vim.api.nvim_buf_get_extmarks(buf,
  vim.api.nvim_create_namespace('codeit_notifications'), 0, -1, { details = true })
assert(marks[1][4].hl_group == 'CodeitNotifyERROR')
assert(marks[2][4].hl_group == 'CodeitNotifyINFO')
assert(marks[3][4].hl_group == 'CodeitNotifyWARN')
for _, level in ipairs({ 'ERROR', 'WARN', 'INFO', 'DEBUG', 'TRACE' }) do
  assert(vim.api.nvim_get_hl(0, { name = 'CodeitNotify' .. level }).link)
end
-- Expiring a middle entry must leave both neighboring entries and their timers intact.
timers[2].callback()
assert(vim.deep_equal(contents(), { '[ERROR] first', '', '[WARN] third', 'more' }))
vim.cmd('tabnew')
local other_origin = vim.api.nvim_get_current_win()
assert(vim.wait(200, function() return window() ~= nil end))
assert(not vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(window()) == buf)
assert(vim.api.nvim_get_current_win() == other_origin)
vim.api.nvim_set_current_tabpage(tab)
assert(vim.wait(200, function() return window() ~= nil end))
assert(vim.api.nvim_get_current_win() == origin)
timers[1].callback()
assert(vim.deep_equal(contents(), { '[WARN] third', 'more' }))
timers[3].callback()
assert(not window() and not vim.api.nvim_buf_is_valid(buf))
-- Reopening after expiry and resizing must keep wrapped Unicode within the screen.
vim.notify('codeit: ' .. string.rep('界é', 80), vim.log.levels.DEBUG)
vim.notify('codeit: trace', vim.log.levels.TRACE)
local columns, rows = vim.o.columns, vim.o.lines
vim.o.columns, vim.o.lines = 35, 12
vim.api.nvim_exec_autocmds('VimResized', {})
vim.wait(20)
config = vim.api.nvim_win_get_config(assert(window()))
assert(config.width <= 31 and config.height <= 8)
for _, line in ipairs(contents()) do assert(vim.fn.strdisplaywidth(line) <= config.width) end
vim.api.nvim_exec_autocmds('ColorScheme', {})
timers[4].callback()
timers[5].callback()
assert(not window())
vim.o.columns, vim.o.lines = columns, rows
-- Closing the view externally must not lose pending messages or break expiry.
vim.notify('codeit: retained')
vim.api.nvim_win_close(assert(window()), true)
vim.notify('codeit: new')
assert(vim.deep_equal(contents(), { '[INFO] retained', '', '[INFO] new' }))
timers[6].callback()
timers[7].callback()
assert(not window())
vim.defer_fn = defer
-- Exercise real independent timers, including notification from a fast event.
local timer = vim.uv.new_timer()
timer:start(0, 0, function()
  timer:stop()
  timer:close()
  vim.notify('codeit: fast event', vim.log.levels.INFO, { timeout = 30 })
end)
assert(vim.wait(200, function() return window() ~= nil end))
vim.notify('codeit: longer', vim.log.levels.WARN, { timeout = 150 })
assert(vim.wait(100, function()
  return window() and vim.deep_equal(contents(), { '[WARN] longer' })
end))
assert(vim.wait(300, function() return window() == nil end))
vim.notify = original_notify
print('codeit notification popup tests passed')
