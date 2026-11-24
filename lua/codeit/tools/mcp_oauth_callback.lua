local M = {}
local uv = vim.uv
local default_port = 33418

local function decode(value)
  return (value:gsub('+', ' '):gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end))
end

function M.listen(port, state, active, done, issuer, require_issuer)
  local server, authority
  local sockets, timer, closed = {}, nil, false
  local function close()
    if closed then return end
    closed = true
    if timer then timer:stop(); timer:close() end
    server:close()
    for socket in pairs(sockets) do if not socket:is_closing() then socket:close() end end
  end
  local function respond(socket, status, message, complete)
    local response = 'HTTP/1.1 ' .. status .. '\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store'
      .. '\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\nContent-Length: ' .. #message .. '\r\n\r\n' .. message
    socket:write(response, function()
      sockets[socket] = nil
      if not socket:is_closing() then socket:close() end
    end)
    if complete then vim.schedule(complete) end
  end
  local claimed = false
  local function accept(err)
    if err or closed then return end
    local socket = assert(uv.new_tcp())
    if not server:accept(socket) or vim.tbl_count(sockets) >= 16 then socket:close(); return end
    sockets[socket] = true
    local input = ''
    socket:read_start(function(read_err, chunk)
      if closed or socket:is_closing() then return end
      if read_err or not chunk then sockets[socket] = nil; socket:close(); return end
      input = input .. chunk
      local boundary = input:find('\r\n\r\n', 1, true)
      if not boundary and #input <= 8192 then return end
      socket:read_stop()
      local query = input:match('^GET /%?([^%s]+) HTTP/1%.[01]\r\n')
      local host, params = nil, {}
      if boundary and boundary <= 8192 and query and not claimed then
        for name, value in input:sub(1, boundary + 1):gmatch('\r\n([^:\r\n]+):[ \t]*([^\r\n]+)') do
          if name:lower() == 'host' then
            if host then host = false; break end
            host = value
          end
        end
        for key, value in query:gmatch('([^&=]+)=([^&]*)') do
          key = decode(key)
          if params[key] ~= nil then params = {}; break end
          params[key] = decode(value)
        end
      end
      local valid_issuer = params.iss == issuer or params.iss == nil and not require_issuer
      if host ~= authority or params.state ~= state or not valid_issuer or not (params.error or params.code and #params.code > 0) then
        return respond(socket, '400 Bad Request', 'Invalid OAuth callback.')
      end
      claimed = true
      local denied = params.error ~= nil
      respond(socket, '200 OK', denied and 'Sign-in was declined. Return to Neovim.'
        or 'OAuth response received. You can return to Neovim.', function()
        if closed then return end
        -- Leave the accepted socket alive long enough to flush its browser response.
        sockets[socket] = nil
        close()
        if active() then done(not denied and params.code or nil, denied and 'OAuth sign-in was declined' or nil) end
      end)
    end)
  end
  local function listen(candidate)
    local socket = assert(uv.new_tcp())
    local ok, err, code = socket:bind('127.0.0.1', candidate)
    if ok then ok, err, code = socket:listen(8, accept) end
    if ok then return socket end
    socket:close()
    return nil, code or err
  end
  local err
  server, err = listen(port or default_port)
  if not server and not port and err and err:find('EADDRINUSE', 1, true) then server = listen(0) end
  if not server then return nil, 'Could not listen for the OAuth loopback callback' end
  authority = '127.0.0.1:' .. server:getsockname().port
  local deadline = uv.hrtime() + 180 * 1e9
  timer = uv.new_timer()
  timer:start(100, 100, vim.schedule_wrap(function()
    if closed then return end
    if not active() then close()
    elseif uv.hrtime() >= deadline then close(); done(nil, 'OAuth sign-in timed out') end
  end))
  return 'http://' .. authority .. '/', close
end

return M
