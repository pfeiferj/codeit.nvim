local M = {}
local versions = { '2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05' }
local max_message = 512 * 1024

function M.start(server, workspace, active, ready)
  local client, process, timer, leave = {}, nil, nil, nil
  local pending, serial, partial, closed = nil, 0, '', false

  function client.close(reason)
    if closed then return end
    closed, client.closed = true, true
    if timer then timer:stop(); timer:close() end
    if leave then vim.api.nvim_del_autocmd(leave) end
    if process then
      if vim.fn.has('unix') == 1 then pcall(vim.uv.kill, -process.pid, 9) end
      pcall(process.kill, process, 9)
    end
    local request = pending
    pending = nil
    if request and active() then request.done(nil, reason or 'MCP connection closed') end
  end

  local function send(message)
    message.jsonrpc = '2.0'
    local encoded = vim.json.encode(message)
    if #encoded > max_message then error('MCP request exceeds the message limit') end
    process:write(encoded .. '\n')
  end

  function client.request(method, params, done)
    if closed then return done(nil, 'MCP connection closed; rediscover the server') end
    if pending then return done(nil, 'MCP server is busy') end
    serial = serial + 1
    pending = { id = serial, deadline = vim.uv.now() + server.timeout_ms, done = done }
    if not pcall(send, { id = serial, method = method, params = params }) then
      client.close('Could not send MCP request')
    end
  end

  local function receive(line)
    local ok, message = pcall(vim.json.decode, line)
    if not ok or type(message) ~= 'table' or message.jsonrpc ~= '2.0' then
      return client.close('Invalid MCP JSON-RPC message on stdout')
    end
    if type(message.method) == 'string' then
      if message.id ~= nil then
        local response = { id = message.id }
        if message.method == 'ping' then response.result = vim.empty_dict()
        else response.error = { code = -32601, message = 'Method not supported' } end
        if not pcall(send, response) then client.close('Could not respond to MCP server request') end
      elseif message.method == 'notifications/tools/list_changed' and client.on_list_changed then
        client.on_list_changed()
      end
      return
    end
    if not pending or message.id ~= pending.id then return end
    local request = pending
    pending = nil
    if type(message.error) == 'table' then
      local text = type(message.error.message) == 'string' and message.error.message or 'unknown error'
      return request.done(nil, 'MCP server error: ' .. require('codeit.utf8').prefix(text, 1000))
    end
    if type(message.result) ~= 'table' then return request.done(nil, 'Invalid MCP response') end
    request.done(message.result)
  end

  local function stdout(err, chunk)
    vim.schedule(function()
      if closed then return end
      if not active() then return client.close() end
      if err then return client.close('Could not read MCP server stdout') end
      if not chunk then return end
      local from = 1
      while not closed do
        local newline = chunk:find('\n', from, true)
        local last = newline and newline - 1 or #chunk
        if #partial + last - from + 1 > max_message then return client.close('MCP message exceeds the size limit') end
        partial = partial .. chunk:sub(from, last)
        if not newline then return end
        local line = partial
        partial, from = '', newline + 1
        if line ~= '' and line ~= '\r' then receive(line) end
      end
    end)
  end

  local ok, handle = pcall(vim.system, vim.list_extend({ server.command }, server.args), {
    cwd = workspace, stdin = true, env = server.env, stdout = stdout, stderr = function() end,
    detached = vim.fn.has('unix') == 1,
  }, vim.schedule_wrap(function(result)
    client.close('MCP server exited (code ' .. result.code .. ')')
  end))
  if not ok then return ready(nil, 'Could not start MCP server; check its executable and configuration') end
  process = handle
  leave = vim.api.nvim_create_autocmd('VimLeavePre', { once = true, callback = function()
    leave, pending = nil, nil
    client.close()
  end })
  timer = vim.uv.new_timer()
  timer:start(100, 100, vim.schedule_wrap(function()
    if closed then return end
    if not active() then client.close()
    elseif pending and vim.uv.now() >= pending.deadline then client.close('MCP request timed out') end
  end))

  client.request('initialize', {
    protocolVersion = versions[1], capabilities = vim.empty_dict(), clientInfo = { name = 'codeit.nvim', version = '1' },
  }, function(result, err)
    if not result or not vim.tbl_contains(versions, result.protocolVersion) or type(result.capabilities) ~= 'table'
      or type(result.capabilities.tools) ~= 'table' then
      client.close()
      return ready(nil, err or 'MCP server did not negotiate a supported tools protocol')
    end
    if not pcall(send, { method = 'notifications/initialized' }) then
      client.close()
      return ready(nil, 'Could not finish MCP initialization')
    end
    ready(client)
  end)
end

return M
