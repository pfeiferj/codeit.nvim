-- Minimal Kitty graphics transport for the rendered-chat viewport. No image
-- conversion, filesystem sharing with the terminal, or external programs.
local M = {}
local ESC = string.char(27)

function M.wrap(sequence, tmux)
  if not tmux then return sequence end
  return ESC .. 'Ptmux;' .. sequence:gsub(ESC, ESC .. ESC) .. ESC .. '\\'
end

function M.command(control, payload)
  return ESC .. '_G' .. control .. ';' .. (payload or '') .. ESC .. '\\'
end

local function ioctl_size(fd)
  local ffi = require('ffi')
  -- Other terminal plugins may already have declared this libc function.
  pcall(ffi.cdef, 'int ioctl(int fd, unsigned long request, ...);')
  local request
  if vim.fn.has('linux') == 1 then request = 0x5413
  elseif vim.fn.has('mac') == 1 or vim.fn.has('bsd') == 1 then request = 0x40087468 end
  if not request then return end
  local size = ffi.new('unsigned short[4]')
  if ffi.C.ioctl(fd, request, size) ~= 0 then return end
  if size[0] > 0 and size[1] > 0 and size[2] > 0 and size[3] > 0 then
    return { cell_width = tonumber(size[2]) / tonumber(size[1]),
      cell_height = tonumber(size[3]) / tonumber(size[0]) }
  end
end

--- Open only for Neovim's built-in TUI. Never emit escapes into a GUI or RPC UI.
function M.open()
  local tui = false
  for _, ui in ipairs(vim.api.nvim_list_uis()) do
    local info = vim.api.nvim_get_chan_info(ui.chan)
    if info.client and info.client.name == 'nvim-tui' then tui = true end
  end
  if not tui then error('Rendered chat requires Neovim in a terminal (Ghostty or Kitty).') end
  local program, term = (vim.env.TERM_PROGRAM or ''):lower(), vim.env.TERM or ''
  if program ~= 'ghostty' and program ~= 'kitty' and not term:find('kitty', 1, true)
    and not term:find('ghostty', 1, true) and not vim.env.KITTY_WINDOW_ID then
    error('Rendered chat requires a Kitty-protocol terminal such as Ghostty or Kitty.')
  end
  local fd = assert(vim.uv.fs_open('/dev/tty', 'r+', 0), 'Cannot open controlling terminal')
  local session = { fd = fd, tmux = vim.env.TMUX ~= nil }

  function session:write(sequence, raw)
    assert(self.fd, 'Terminal transport is closed')
    local data = raw and sequence or M.wrap(sequence, self.tmux)
    local offset = 1
    while offset <= #data do
      local count, err = vim.uv.fs_write(self.fd, data:sub(offset), -1)
      assert(count and count > 0, err or 'Could not write terminal graphics')
      offset = offset + count
    end
  end

  -- SSH/tmux can omit pixel dimensions from TIOCGWINSZ. Ask the terminal for
  -- cell dimensions rather than guessing and inadvertently scaling/clipping.
  function session:measure(callback)
    local ok, size = pcall(ioctl_size, self.fd)
    if ok and size then callback(size); return end
    self.response = vim.api.nvim_create_autocmd('TermResponse', { callback = function(event)
      local response = event.data and event.data.sequence or vim.v.termresponse
      local h, w = response:match(ESC .. '%[6;(%d+);(%d+)t')
      if not h or tonumber(h) <= 0 or tonumber(w) <= 0 then return end
      self:stop_measure()
      callback({ cell_width = tonumber(w), cell_height = tonumber(h) })
    end })
    self.timer = vim.defer_fn(function()
      self:stop_measure()
      callback(nil, 'Cannot determine terminal pixel size. Check tmux passthrough or use Ghostty directly.')
    end, 1500)
    self:write(ESC .. '[16t')
  end

  function session:stop_measure()
    if self.response then pcall(vim.api.nvim_del_autocmd, self.response); self.response = nil end
    if self.timer then
      if not self.timer:is_closing() then self.timer:stop(); self.timer:close() end
      self.timer = nil
    end
  end

  function session:close()
    self:stop_measure()
    if self.fd then vim.uv.fs_close(self.fd); self.fd = nil end
  end
  return session
end

--- Upload PNG bytes once, in base64 chunks no larger than the protocol's 4096
--- byte limit. The terminal does not need access to Neovim's temporary file.
function M.upload(terminal, id, path)
  local file = assert(io.open(path, 'rb'))
  local first = true
  local ok, err = pcall(function()
    while true do
      local bytes = file:read(3072)
      if not bytes then break end
      local control = first and ('a=t,t=d,f=100,i=%d,q=2,m=1'):format(id) or 'm=1,q=2'
      terminal:write(M.command(control, vim.base64.encode(bytes)))
      first = false
    end
    assert(not first, 'Rendered PNG is empty')
    terminal:write(M.command('m=0,q=2'))
  end)
  file:close()
  if not ok then error(err) end
end

--- x/y/w/h are source pixels; intentionally omit c/r (which request scaling).
function M.place(terminal, id, win, offset, image, cell)
  local position = vim.api.nvim_win_get_position(win)
  local w = math.min(image.width, math.floor(vim.api.nvim_win_get_width(win) * cell.cell_width))
  local h = math.min(image.height, math.floor(vim.api.nvim_win_get_height(win) * cell.cell_height))
  local y = math.max(0, math.min(image.height - h, math.floor(offset * cell.cell_height)))
  local control = ('a=p,i=%d,p=1,q=2,C=1,x=0,y=%d,w=%d,h=%d,z=1'):format(id, y, w, h)
  -- Let tmux process cursor movement (pane-relative coordinates), but pass
  -- the graphics APC through. Saving/restoring keeps its cursor in sync with
  -- Neovim's. Wrapping CUP itself would incorrectly position in screen space.
  terminal:write(ESC .. '7' .. ('%s[%d;%dH'):format(ESC, position[1] + 1, position[2] + 1)
    .. M.wrap(M.command(control), terminal.tmux) .. ESC .. '8', true)
end

function M.delete(terminal, id)
  terminal:write(M.command(('a=d,d=I,i=%d,q=2'):format(id)))
end

return M
