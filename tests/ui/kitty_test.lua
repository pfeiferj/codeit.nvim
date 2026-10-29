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
local ui_send, guess_handle = vim.api.nvim_ui_send, vim.uv.guess_handle
vim.api.nvim_ui_send = nil -- Exercise the legacy descriptor transport explicitly.
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
-- Modern split-TUI Neovim needs no controlling terminal or inherited TTY.
local sent = {}
vim.api.nvim_ui_send = function(data) sent[#sent + 1] = data end
vim.uv.fs_open = function() error('ui_send must not open /dev/tty') end
vim.uv.fs_write = function() error('ui_send must not write an editor descriptor') end
vim.uv.fs_close = function() error('ui_send must not close editor descriptors') end
vim.uv.guess_handle = function() return 'pipe' end
local routed = kitty.open()
routed:write(apc)
assert(sent[1] == kitty.wrap(apc, true))
local dimensions
routed:measure(function(size) dimensions = size end)
vim.api.nvim_exec_autocmds('TermResponse', { data = { sequence = esc .. '[6;24;12t' } })
assert(dimensions.cell_width == 12 and dimensions.cell_height == 24)
routed:close()
assert(not pcall(function() routed:write(apc) end))

-- Older Neovim may still inherit a TTY even when /dev/tty returns ENXIO.
-- Borrow only a verified TTY, and never close the inherited descriptor.
vim.api.nvim_ui_send = nil
vim.uv.fs_open = function() return nil, 'ENXIO: no such device or address: /dev/tty' end
vim.uv.guess_handle = function(fd) return fd == 2 and 'tty' or 'pipe' end
local borrowed_output = ''
vim.uv.fs_write = function(fd, data)
  assert(fd == 2)
  borrowed_output = borrowed_output .. data
  return #data
end
local borrowed = kitty.open()
borrowed:write(apc)
assert(borrowed_output == kitty.wrap(apc, true))

-- Reproduce nonblocking TTY backpressure, including a partial write before
-- EAGAIN. Every byte and tmux envelope must arrive exactly once, in order.
local hrtime, sleep = vim.uv.hrtime, vim.uv.sleep
local clock, sleeps, attempts = 0, 0, 0
vim.uv.hrtime = function() return clock end
vim.uv.sleep = function(ms) clock = clock + ms * 1000000; sleeps = sleeps + 1 end
borrowed_output = ''
vim.uv.fs_write = function(fd, data)
  assert(fd == 2)
  attempts = attempts + 1
  if attempts == 1 or attempts == 4 then
    return nil, 'EAGAIN: resource temporarily unavailable', 'EAGAIN'
  elseif attempts == 2 then
    return nil, 'EWOULDBLOCK: operation would block' -- Error-string fallback.
  elseif attempts == 5 then
    return nil, 'EINTR: interrupted system call', 'EINTR'
  end
  local count = math.min(7, #data)
  borrowed_output = borrowed_output .. data:sub(1, count)
  return count
end
borrowed:write(apc)
assert(borrowed_output == kitty.wrap(apc, true), 'backpressure must not duplicate or drop bytes')
assert(sleeps == 4, 'transient errors must wait instead of busy-spinning')

-- Permanent errors fail immediately; a stalled TTY has a bounded wait.
vim.uv.fs_write = function() return nil, 'EIO: input/output error', 'EIO' end
local waits_before = sleeps
local wrote, write_error = pcall(function() borrowed:write(apc) end)
assert(not wrote and tostring(write_error):find('EIO', 1, true))
assert(sleeps == waits_before)
vim.uv.fs_write = function() return nil, 'EAGAIN: resource temporarily unavailable', 'EAGAIN' end
local start = clock
wrote, write_error = pcall(function() borrowed:write(apc) end)
assert(not wrote and tostring(write_error):find('Timed out waiting for terminal output', 1, true))
assert(clock - start >= 2000000000 and clock - start <= 2010000000)
vim.uv.fs_write = function() return 0 end
waits_before = sleeps
assert(not pcall(function() borrowed:write(apc) end), 'zero-byte writes must not spin forever')
assert(sleeps == waits_before)
vim.uv.hrtime, vim.uv.sleep = hrtime, sleep
borrowed:close() -- fs_close above still raises if called.

-- With only RPC pipes, fail with the real open error instead of corrupting RPC.
vim.uv.guess_handle = function() return 'pipe' end
local accessible, message = pcall(kitty.open)
assert(not accessible and tostring(message):find('ENXIO', 1, true))
assert(tostring(message):find('nvim_ui_send', 1, true))
vim.api.nvim_ui_send, vim.uv.guess_handle = ui_send, guess_handle
vim.api.nvim_list_uis, vim.api.nvim_get_chan_info = list_uis, chan_info
vim.uv.fs_open, vim.uv.fs_write, vim.uv.fs_close = fs_open, fs_write, fs_close
vim.env.TERM_PROGRAM, vim.env.TMUX = program, tmux
print('kitty_test: passed')
