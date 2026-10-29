vim.opt.runtimepath:prepend(vim.fn.getcwd())
local kitty = require('codeit.ui.kitty')
local esc = string.char(27)
local apc = kitty.command('a=d,d=I,i=42,q=2')
assert(apc == esc .. '_Ga=d,d=I,i=42,q=2;' .. esc .. '\\')
assert(kitty.wrap(apc, false) == apc)
assert(kitty.wrap(apc, true) == esc .. 'Ptmux;' .. apc:gsub(esc, esc .. esc) .. esc .. '\\')

local terminal = { writes = {} }
function terminal:write(sequence, raw) self.writes[#self.writes + 1] = { sequence, raw } end
local path = vim.fn.tempname() .. '.png'
local bytes = string.rep('abc', 3000) .. 'x'
vim.fn.writefile({ bytes }, path, 'b')
kitty.upload(terminal, 42, path)
vim.fn.delete(path)
local chunks = {}
for index, entry in ipairs(terminal.writes) do
  local sequence = entry[1]
  local control, payload = sequence:match('^' .. esc .. '_G(.-);(.*)' .. esc .. '\\$')
  assert(control and payload)
  assert(#payload <= 4096 and #payload % 4 == 0)
  if index == 1 then
    assert(control == 'a=t,t=d,f=100,i=42,q=2,m=1')
  elseif index == #terminal.writes then
    assert(control == 'm=0,q=2' and payload == '')
  else
    assert(control == 'm=1,q=2', 'continuation chunks must not repeat upload metadata')
  end
  chunks[#chunks + 1] = payload
end
assert(vim.base64.decode(table.concat(chunks)) == bytes)

local win = vim.api.nvim_get_current_win()
local cell = { cell_width = 10, cell_height = 20 }
local image = { width = vim.api.nvim_win_get_width(win) * 10, height = 10000 }
kitty.place(terminal, 42, win, 3, image, cell)
local sequence = terminal.writes[#terminal.writes][1]
assert(sequence:find('a=p,i=42,p=1,q=2,C=1,x=0,y=60,', 1, true))
assert(not sequence:match(',[cr]='), 'c/r would scale the image')
assert(sequence:sub(1, 2) == esc .. '7' and sequence:sub(-2) == esc .. '8')
local position = vim.api.nvim_win_get_position(win)
assert(sequence:find(('%s[%d;%dH'):format(esc, position[1] + 1, position[2] + 1), 1, true))

kitty.place(terminal, 42, win, 99999, image, cell)
sequence = terminal.writes[#terminal.writes][1]
local y = tonumber(sequence:match(',y=(%d+),'))
local h = tonumber(sequence:match(',h=(%d+),'))
assert(y + h == image.height, 'bottom crop must end exactly at the final image pixel')
kitty.place(terminal, 42, win, 99, { width = 50, height = 53 }, cell)
sequence = terminal.writes[#terminal.writes][1]
assert(sequence:find('y=0,w=50,h=53,', 1, true), 'short images keep native dimensions')

terminal.tmux = true
kitty.place(terminal, 42, win, 0, image, cell)
sequence = terminal.writes[#terminal.writes][1]
assert(sequence:sub(1, 2) == esc .. '7', 'cursor positioning must be interpreted by tmux')
assert(sequence:find(esc .. 'Ptmux;' .. esc .. esc .. '_Ga=p,', 1, true))
assert(terminal.writes[#terminal.writes][2] == true, 'mixed cursor/APC sequence is already wrapped')
kitty.delete(terminal, 42)
assert(terminal.writes[#terminal.writes][1] == apc, 'delete only this image, never unrelated images')

-- Never emit terminal escapes in headless Neovim / GUI-only sessions.
local list_uis = vim.api.nvim_list_uis
vim.api.nvim_list_uis = function() return {} end
local ok, err = pcall(kitty.open)
vim.api.nvim_list_uis = list_uis
assert(not ok and tostring(err):find('requires Neovim in a terminal', 1, true))
-- Exercise the real transport with a fake TTY descriptor: ioctl fails, then
-- TermResponse supplies exact cell dimensions. Partial writes must be retried
-- within the write operation, without losing bytes or duplicating envelopes.
local chan_info = vim.api.nvim_get_chan_info
local fs_open, fs_write, fs_close = vim.uv.fs_open, vim.uv.fs_write, vim.uv.fs_close
local program, tmux = vim.env.TERM_PROGRAM, vim.env.TMUX
vim.env.TERM_PROGRAM, vim.env.TMUX = 'ghostty', 'test-tmux'
vim.api.nvim_list_uis = function() return { { chan = 123 } } end
vim.api.nvim_get_chan_info = function() return { client = { name = 'nvim-tui' } } end
local output, closed = '', false
vim.uv.fs_open = function(name) assert(name == '/dev/tty'); return 999999 end
vim.uv.fs_write = function(fd, data)
  assert(fd == 999999)
  local count = math.min(7, #data)
  output = output .. data:sub(1, count)
  return count
end
vim.uv.fs_close = function(fd) assert(fd == 999999); closed = true end
local session = kitty.open()
session:write(apc)
assert(output == kitty.wrap(apc, true))
local measured
session:measure(function(size) measured = size end)
assert(output:find(kitty.wrap(esc .. '[16t', true), 1, true))
vim.api.nvim_exec_autocmds('TermResponse', { data = { sequence = esc .. '[6;0;0t' } })
assert(not measured, 'ignore invalid cell-size replies')
vim.api.nvim_exec_autocmds('TermResponse', { data = { sequence = esc .. '[6;20;10t' } })
assert(measured.cell_width == 10 and measured.cell_height == 20)
assert(not session.timer and not session.response)
session:close()
assert(closed and not session.fd)

-- Closing while measurement is pending cancels both the timeout and listener.
local pending = kitty.open()
local called = false
pending:measure(function() called = true end)
pending:close()
vim.api.nvim_exec_autocmds('TermResponse', { data = { sequence = esc .. '[6;20;10t' } })
assert(not called and not pending.timer and not pending.response)
vim.api.nvim_list_uis, vim.api.nvim_get_chan_info = list_uis, chan_info
vim.uv.fs_open, vim.uv.fs_write, vim.uv.fs_close = fs_open, fs_write, fs_close
vim.env.TERM_PROGRAM, vim.env.TMUX = program, tmux
print('kitty_test: passed')
