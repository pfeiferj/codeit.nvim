vim.opt.runtimepath:prepend(vim.fn.getcwd())
local root = vim.fn.getcwd()
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
vim.fn.writefile({ 'regular file' }, dir .. '/file.txt')
vim.cmd.cd(dir)
vim.g.netrw_dirhistmax = 0
vim.cmd('runtime plugin/netrwPlugin.vim')
vim.cmd('Explore .')
local explorer = vim.api.nvim_get_current_buf()
assert(vim.bo[explorer].filetype == 'netrw' and vim.bo[explorer].buftype == '')
local listing = vim.api.nvim_buf_get_lines(explorer, 0, -1, false)
assert(#listing > 1)
local buffers = require('codeit.file_buffer')
local layout = require('codeit.ui.managed_tab')
assert(not buffers.ordinary(explorer))
assert(not buffers.target({ buffer_id = explorer }))
assert(not buffers.target({}, explorer))
for _, entry in ipairs(buffers.list(explorer, true)) do assert(entry.id ~= explorer) end
buffers.refresh(explorer)
assert(vim.deep_equal(listing, vim.api.nvim_buf_get_lines(explorer, 0, -1, false)))

-- Opening the chat from netrw must not capture or inherit the directory view.
local api, session = { send = function() end }, {}
local helpers = { render = function() end }
require('codeit.chat.session').attach(api, session, helpers)
helpers.sync_workspace = function() end
api.open()
assert(session.source == nil)
local win = layout.windows()[1]
assert(win and layout.buffer(win) ~= explorer)
assert(vim.api.nvim_buf_get_name(layout.buffer(win)) == '')
assert(not layout.user_visible(explorer))

-- Netrw remains usable in the managed tab, but is not an assistant file target.
vim.api.nvim_set_current_win(win)
vim.cmd('Explore .')
explorer = vim.api.nvim_get_current_buf()
listing = vim.api.nvim_buf_get_lines(explorer, 0, -1, false)
assert(vim.bo[explorer].filetype == 'netrw' and #listing > 1)
assert(layout.buffer(win) == nil and #layout.windows() == 0)
assert(not layout.user_visible(explorer))
local windows = require('codeit.tools.windows')
local function call(name, args)
  local result
  windows.execute(name, args or {}, function(value) result = value end, {})
  assert(result)
  return result
end
assert(#vim.json.decode(call('list_windows')).windows == 0)
for _, name in ipairs({ 'read_window_buffer', 'close_window', 'split_window', 'open_window_file' }) do
  assert(call(name, { window_id = win, path = 'file.txt' }):match('^Error:'))
end
assert(vim.deep_equal(listing, vim.api.nvim_buf_get_lines(explorer, 0, -1, false)))
assert(vim.api.nvim_win_is_valid(win))

-- A regular file opened from the explorer is a normal user attachment again.
vim.cmd.edit(vim.fn.fnameescape(dir .. '/file.txt'))
local file = vim.api.nvim_get_current_buf()
assert(buffers.ordinary(file) and layout.buffer(win) == file and layout.user_visible(file))
assert(vim.json.decode(call('read_window_buffer', { window_id = win })).lines[1] == 'regular file')
require('codeit.ui').close()
vim.cmd.cd(root)
vim.fn.delete(dir, 'rf')
print('Netrw buffer and managed-window isolation: passed')
