local M = {}
local uv = vim.uv
local default_port = 33418

local function decode(value)
  return (value:gsub('+', ' '):gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end))
end

local function response(status, message)
  return 'HTTP/1.1 ' .. status .. '\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store'
    .. '\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\nContent-Length: ' .. #message .. '\r\n\r\n' .. message
end

local function handler(state, issuer, require_issuer, host, advertised_port)
  local advertised = advertised_port and host .. ':' .. advertised_port
  local claimed = false
  return function(input, authority)
    local boundary = input:find('\r\n\r\n', 1, true)
    local query = input:match('^GET /[^?%s]*%?([^%s]+) HTTP/1%.[01]\r\n')
    local request_host, params = nil, {}
    if boundary and boundary <= 8192 and query and not claimed then
      for name, value in input:sub(1, boundary + 1):gmatch('\r\n([^:\r\n]+):[ \t]*([^\r\n]+)') do
        if name:lower() == 'host' then
          if request_host then request_host = false; break end
          request_host = value:lower()
        end
      end
      for key, value in query:gmatch('([^&=]+)=([^&]*)') do
        key = decode(key)
        if params[key] ~= nil then params = {}; break end
        params[key] = decode(value)
      end
    end
    local valid_issuer = params.iss == issuer or params.iss == nil and not require_issuer
    -- A port forward can preserve the browser's original loopback Host header.
    local valid_host = request_host == authority or (advertised ~= nil and request_host == advertised)
    if not valid_host or params.state ~= state or not valid_issuer or not (params.error or params.code and #params.code > 0) then
      return response('400 Bad Request', 'Invalid OAuth callback.')
    end
    claimed = true
    local denied = params.error ~= nil
    return response('200 OK', denied and 'Sign-in was declined. Return to Neovim.'
      or 'OAuth response received. You can return to Neovim.'),
      not denied and params.code or nil, denied and 'OAuth sign-in was declined' or nil
  end
end

function M.listen(port, state, active, done, issuer, require_issuer, path, advertised_port, host)
  path = path or '/'
  host = host or '127.0.0.1'
  local bind_host = host == 'localhost' and '127.0.0.1' or host
  local handle = handler(state, issuer, require_issuer, host, advertised_port)
  local server, authority
  local sockets, timer, closed = {}, nil, false
  local function close()
    if closed then return end
    closed = true
    if timer then timer:stop(); timer:close() end
    server:close()
    for socket in pairs(sockets) do if not socket:is_closing() then socket:close() end end
  end
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
      local reply, code, failure = handle(input, authority)
      socket:write(reply, function()
        sockets[socket] = nil
        if not socket:is_closing() then socket:close() end
      end)
      if code or failure then
        vim.schedule(function()
          if closed then return end
          -- Leave the accepted socket alive long enough to flush its browser response.
          sockets[socket] = nil
          close()
          if active() then done(code, failure) end
        end)
      end
    end)
  end
  local function listen(candidate)
    local socket = assert(uv.new_tcp())
    local ok, err, code = socket:bind(bind_host, candidate)
    if ok then ok, err, code = socket:listen(8, accept) end
    if ok then return socket end
    socket:close()
    return nil, code or err
  end
  local err
  server, err = listen(port or default_port)
  if not server and not port and err and err:find('EADDRINUSE', 1, true) then server = listen(0) end
  if not server then return nil, 'Could not listen for the OAuth loopback callback' end
  authority = host .. ':' .. server:getsockname().port
  local deadline = uv.hrtime() + 180 * 1e9
  timer = uv.new_timer()
  timer:start(100, 100, vim.schedule_wrap(function()
    if closed then return end
    if not active() then close()
    elseif uv.hrtime() >= deadline then close(); done(nil, 'OAuth sign-in timed out') end
  end))
  return 'http://' .. authority .. path, close
end

function M.listen_https(port, state, active, done, issuer, require_issuer, path, advertised_port, host, ready)
  local script = vim.api.nvim_get_runtime_file('lua/codeit/tools/mcp_oauth_tls.py', false)[1]
  if not script then return ready(nil, 'MCP OAuth HTTPS callback helper is missing') end
  local cert, key = vim.env.CODEIT_MCP_OAUTH_TLS_CERT, vim.env.CODEIT_MCP_OAUTH_TLS_KEY
  if ((cert or '') ~= '') ~= ((key or '') ~= '') then
    return ready(nil, 'Set both CODEIT_MCP_OAUTH_TLS_CERT and CODEIT_MCP_OAUTH_TLS_KEY, or neither')
  end
  local bind_host = host == 'localhost' and '127.0.0.1' or host
  local handle = handler(state, issuer, require_issuer, host, advertised_port)
  local child, authority, code, failure
  local closed, buffer = false, ''
  local deadline = uv.hrtime() + 12 * 1e9
  local timer = uv.new_timer()
  local function stop()
    if closed then return end
    closed = true
    timer:stop(); timer:close()
    if child then pcall(child.write, child, nil) end
  end
  local function fail(message)
    stop()
    if not active() then return end
    if authority then done(nil, message) else ready(nil, message) end
  end
  local function line_received(line)
    local bound_port = line:match('^ready (%d+)$')
    if bound_port then
      authority = host .. ':' .. bound_port
      deadline = uv.hrtime() + 180 * 1e9
      ready('https://' .. authority .. path, stop)
    elseif line == 'certificate_error' then
      fail('Could not load the MCP OAuth TLS certificate and key or generate a self-signed certificate with OpenSSL')
    elseif line == 'listen_error' then
      fail('Could not listen for the HTTPS OAuth loopback callback')
    elseif line == 'sent' then
      if code or failure then
        stop()
        if active() then done(code, failure) end
      end
    else
      local encoded = line:match('^request (.+)$')
      if not encoded or not authority then return fail('Invalid response from the MCP OAuth HTTPS callback helper') end
      local reply
      reply, code, failure = handle(vim.base64.decode(encoded), authority)
      local ok = pcall(child.write, child, vim.base64.encode(reply) .. '\n')
      if not ok then fail('Could not write to the MCP OAuth HTTPS callback helper') end
    end
  end
  local ok, process = pcall(vim.system, { 'python3', '-I', script, bind_host, tostring(port), host }, {
    stdin = true,
    stdout = vim.schedule_wrap(function(err, chunk)
      if closed then return end
      if not active() then return stop() end
      if err then return fail('Could not read from the MCP OAuth HTTPS callback helper') end
      if not chunk then return end
      buffer = buffer .. chunk
      while not closed do
        local newline = buffer:find('\n', 1, true)
        if not newline then break end
        local line = buffer:sub(1, newline - 1):gsub('\r$', '')
        buffer = buffer:sub(newline + 1)
        line_received(line)
      end
    end),
    stderr = function() end,
  }, vim.schedule_wrap(function()
    if not closed then fail('MCP OAuth HTTPS callback helper exited unexpectedly') end
  end))
  if not ok then return fail('MCP OAuth HTTPS callbacks require python3') end
  child = process
  timer:start(100, 100, vim.schedule_wrap(function()
    if closed then return end
    if not active() then stop()
    elseif uv.hrtime() >= deadline then
      fail(authority and 'OAuth sign-in timed out' or 'MCP OAuth HTTPS callback listener did not start in time')
    end
  end))
end

return M
