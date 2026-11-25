local M = {}
local http = require('codeit.tools.mcp_http')
local versions = { '2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05' }

local function connect(server, active, ready, token, invalidate)
  local headers, err = http.headers(server)
  if not headers then return ready(nil, err) end
  if token then headers.Authorization = 'Bearer ' .. token end
  local client, serial, session, version = {}, 0, nil, nil
  local pending, timer, leave
  headers.Accept = 'application/json, text/event-stream'
  headers['Content-Type'] = 'application/json'
  local function request_headers()
    local result = vim.tbl_extend('force', {}, headers)
    result['Mcp-Session-Id'], result['MCP-Protocol-Version'] = session, version
    return result
  end
  function client.close(skip_delete)
    if client.closed then return end
    client.closed = true
    if pending and pending.cancel then pending.cancel() end
    pending = nil
    if timer then timer:stop(); timer:close() end
    if leave then vim.api.nvim_del_autocmd(leave) end
    if session and not skip_delete then
      http.request('DELETE', server.url, request_headers(), nil, 2000, function() end)
    end
  end
  local function rpc(method, params, notification, done)
    if client.closed then return done(nil, 'MCP connection closed; rediscover the server') end
    if pending then return done(nil, 'MCP server is busy') end
    serial = serial + 1
    local id = not notification and serial or nil
    local request = {}
    pending = request
    local function finish(result, failure, challenge)
      if pending ~= request then return end
      pending = nil
      if request.cancel then request.cancel() end
      if active() then done(result, failure, challenge) else client.close() end
    end
    local function receive(value, response_headers)
      if type(value) ~= 'table' or value.jsonrpc ~= '2.0' then return finish(nil, 'Invalid MCP JSON-RPC response') end
      if value.method == 'notifications/tools/list_changed' and value.id == nil and client.on_list_changed then
        return client.on_list_changed()
      end
      if type(value.method) == 'string' and value.id ~= nil then
        local reply = { jsonrpc = '2.0', id = value.id }
        if value.method == 'ping' then reply.result = vim.empty_dict()
        else reply.error = { code = -32601, message = 'Method not supported' } end
        http.request('POST', server.url, request_headers(), reply, math.min(server.timeout_ms, 5000), function() end)
        return
      end
      if not id or value.id ~= id then return end
      if method == 'initialize' then
        local candidate = response_headers['mcp-session-id']
        if candidate and (candidate == '' or #candidate > 4096 or candidate:find('[^!-~]')) then
          return finish(nil, 'Invalid MCP session ID')
        end
        session = candidate
      end
      if type(value.error) == 'table' then
        local message = type(value.error.message) == 'string' and value.error.message or 'unknown error'
        return finish(nil, 'MCP server error: ' .. require('codeit.utf8').prefix(message, 1000))
      end
      if type(value.result) ~= 'table' then return finish(nil, 'Invalid MCP result') end
      finish(value.result)
    end
    local partial, data = '', {}
    local function stream(chunk, response_headers)
      partial = partial .. chunk
      while pending == request do
        local newline = partial:find('\n', 1, true)
        if not newline then return end
        local line = partial:sub(1, newline - 1):gsub('\r$', '')
        partial = partial:sub(newline + 1)
        if line == '' and #data > 0 then
          local raw = table.concat(data, '\n')
          data = {}
          if raw ~= '' then
            local ok, value = pcall(vim.json.decode, raw)
            if not ok then return finish(nil, 'Invalid MCP SSE event') end
            receive(value, response_headers)
          end
        elseif line == 'data' or line:sub(1, 5) == 'data:' then
          data[#data + 1] = line:sub(6):gsub('^ ', '')
        end
      end
    end
    request.cancel = http.request('POST', server.url, request_headers(), {
      jsonrpc = '2.0', id = id, method = method, params = params,
    }, server.timeout_ms, function(response, failure)
      if not response then return finish(nil, failure) end
      if response.status == 404 and session then
        session = nil
        client.close(true)
        if active() then done(nil, 'MCP session expired; rediscover the server') end
        return
      end
      if response.status == 401 or response.status == 403 then
        local failure = 'MCP endpoint returned HTTP ' .. response.status .. '; check authentication and permissions'
        if response.status == 401 and server.oauth then
          if token then invalidate(token) end
          if method == 'initialize' then return finish(nil, failure, response.headers['www-authenticate'] or '') end
          client.close(true)
          if active() then done(nil, failure .. '; rediscover the server to sign in again') end
          return
        end
        return finish(nil, failure)
      end
      if response.status < 200 or response.status >= 300 then
        return finish(nil, 'MCP endpoint returned HTTP ' .. response.status)
      end
      if notification then return finish(true) end
      if (response.headers['content-type'] or ''):lower():match('^text/event%-stream') then
        return finish(nil, 'MCP event stream ended before the response')
      end
      local ok, value = pcall(vim.json.decode, response.body)
      if not ok then return finish(nil, 'Invalid MCP HTTP JSON response') end
      receive(value, response.headers)
      if pending == request then finish(nil, 'MCP response did not match the request') end
    end, stream)
  end
  function client.request(method, params, done) rpc(method, params, false, done) end
  timer = vim.uv.new_timer()
  timer:start(100, 100, vim.schedule_wrap(function() if not active() then client.close() end end))
  leave = vim.api.nvim_create_autocmd('VimLeavePre', { once = true, callback = function()
    leave = nil
    client.close(true)
  end })
  client.request('initialize', {
    protocolVersion = versions[1], capabilities = vim.empty_dict(), clientInfo = { name = 'codeit.nvim', version = '1' },
  }, function(result, failure, challenge)
    if not result or not vim.tbl_contains(versions, result.protocolVersion) or type(result.capabilities) ~= 'table'
      or type(result.capabilities.tools) ~= 'table' then
      client.close()
      return ready(nil, failure or 'MCP server did not negotiate a supported tools protocol', challenge)
    end
    version = result.protocolVersion
    rpc('notifications/initialized', nil, true, function(ok, notify_err)
      if ok then ready(client) else client.close(); ready(nil, notify_err) end
    end)
  end)
end

function M.sign_in(server, cache, active, done)
  if not server.oauth then return done(nil, 'MCP server does not use browser OAuth') end
  local function login(challenge)
    require('codeit.tools.mcp_oauth').login(server, challenge, cache or {}, active, function(token, err)
      done(token ~= nil, err)
    end, true)
  end
  if server.oauth.authorization_url then return login('') end
  connect(server, active, function(client, failure, challenge)
    if client then client.close() end
    if not client and challenge == nil then return done(nil, failure) end
    login(challenge or '')
  end)
end

function M.start(server, _, active, ready, cache)
  if not server.oauth then return connect(server, active, ready) end
  local oauth = require('codeit.tools.mcp_oauth')
  cache = cache or {}
  local function invalidate(token) oauth.invalidate(server, cache, token) end
  connect(server, active, function(client, failure, challenge)
    if client or challenge == nil then return ready(client, failure) end
    oauth.login(server, challenge, cache, active, function(token, err)
      if not token then return ready(nil, err) end
      connect(server, active, function(connected, connect_err) ready(connected, connect_err) end, token, invalidate)
    end)
  end, oauth.token(server, cache), invalidate)
end

return M
