vim.opt.runtimepath:prepend(vim.fn.getcwd())
local uv = vim.uv
local server = assert(uv.new_tcp())
assert(server:bind('127.0.0.1', 0))
local url = 'http://127.0.0.1:' .. server:getsockname().port
vim.env.NO_PROXY, vim.env.no_proxy = '127.0.0.1', '127.0.0.1'
vim.env.TEST_MCP_TOKEN = 'test-token'
local failures, seen, clients = {}, {}, {}
local function respond(socket, status, headers, body, hold)
  body = body or ''
  socket:write('HTTP/1.1 ' .. status .. '\r\n' .. headers .. '\r\nContent-Length: '
    .. (#body + (hold and 100 or 0)) .. '\r\nConnection: close\r\n\r\n' .. body)
end
local function json(socket, value, headers)
  respond(socket, '200 OK', 'Content-Type: application/json' .. (headers or ''), vim.json.encode(value))
end
local function handle(socket, method, path, headers, body)
  if path:find('^/v0%.1/servers%?') then
    assert(method == 'GET' and headers.authorization == 'Bearer test-token')
    assert(path:find('search=a%20%26b', 1, true))
    local page = path:find('cursor=x%2By%3D', 1, true)
    return json(socket, { servers = { { server = { name = page and 'test/second' or 'test/first', description = 'Search demo',
      remotes = { { type = 'sse', url = 'https://example.invalid/legacy' }, { type = 'streamable-http', url = 'https://example.invalid/mcp' } } } },
      { server = { name = 'test/deleted' }, _meta = { ['io.modelcontextprotocol.registry/official'] = { status = 'deleted' } } } },
      metadata = page and vim.empty_dict() or { nextCursor = 'x+y=' } })
  end
  assert(path == '/mcp' and headers.authorization == 'Bearer test-token')
  if method == 'DELETE' then
    assert(headers['mcp-session-id'] == 'test-session')
    seen.delete = true
    return respond(socket, '204 No Content', 'Content-Type: application/json')
  end
  assert(method == 'POST' and headers.accept == 'application/json, text/event-stream')
  local request = vim.json.decode(body)
  assert(request.jsonrpc == '2.0')
  local reply = { jsonrpc = '2.0', id = request.id }
  if request.method == 'initialize' then
    assert(not headers['mcp-session-id'])
    reply.result = { protocolVersion = '2025-06-18', capabilities = { tools = vim.empty_dict() } }
    return json(socket, reply, '\r\nMcp-Session-Id: test-session')
  end
  assert(headers['mcp-protocol-version'] == '2025-06-18' and headers['mcp-session-id'] == 'test-session')
  if request.method == 'notifications/initialized' then
    assert(request.id == nil)
    seen.initialized = true
    return respond(socket, '202 Accepted', 'Content-Type: application/json')
  end
  assert(seen.initialized)
  if request.method == 'tools/list' then
    reply.result = { tools = { { name = 'echo', inputSchema = { type = 'object' } } } }
    local notification = { jsonrpc = '2.0', method = 'notifications/tools/list_changed' }
    return respond(socket, '200 OK', 'Content-Type: text/event-stream', ': keepalive\r\n\r\n'
      .. (seen.no_change and '' or ('data: ' .. vim.json.encode(notification) .. '\r\n\r\n'))
      .. 'data: ' .. vim.json.encode(reply) .. '\r\n\r\n', true)
  end
  assert(request.method == 'tools/call' and request.params.name == 'echo')
  if request.params.arguments.expire then return respond(socket, '404 Not Found', 'Content-Type: application/json') end
  reply.result = { structuredContent = request.params.arguments }
  json(socket, reply)
end
assert(server:listen(16, function(err)
  if err then return end
  local socket = assert(uv.new_tcp())
  clients[#clients + 1] = socket
  assert(server:accept(socket))
  local data = ''
  socket:read_start(function(read_err, chunk)
    if read_err or not chunk then if not socket:is_closing() then socket:close() end; return end
    data = data .. chunk
    local block, body = data:match('^(.-)\r\n\r\n(.*)$')
    if not block then return end
    local headers = {}
    for name, value in block:gmatch('\r\n([^:\r\n]+):%s*([^\r\n]*)') do headers[name:lower()] = value end
    if #body < (tonumber(headers['content-length']) or 0) then return end
    socket:read_stop()
    local method, path = block:match('^(%u+) (%S+) HTTP/')
    vim.schedule(function()
      local ok, failure = pcall(handle, socket, method, path, headers, body)
      if not ok then failures[#failures + 1] = failure; socket:close() end
    end)
  end)
end))
local function wait(read)
  assert(vim.wait(5000, function() return read() or #failures > 0 end), 'request did not complete')
  assert(#failures == 0, failures[1])
  return read()
end

local mcp = require('codeit.tools.mcp')
local registry = require('codeit.tools.mcp_registry')
local remote = require('codeit.tools.mcp_remote')
local config = mcp.configure({ servers = { sample = { url = url .. '/mcp', bearer_token_env = 'TEST_MCP_TOKEN', timeout_ms = 1500 } } })
local live, client, error_text = true
local function connect()
  client, error_text, seen.initialized = nil, nil, nil
  remote.start(config.servers.sample, nil, function() return live end, function(value, err) client, error_text = value, err end)
  wait(function() return client or error_text end)
  assert(client, error_text)
end
local function rpc(method, params)
  local result, err
  client.request(method, params, function(value, failure) result, err = value, failure end)
  wait(function() return result or err end)
  return result, err
end
connect()
client.on_list_changed = function() seen.changed = true end
assert(assert(rpc('tools/list')).tools[1].name == 'echo' and seen.changed)
local arguments = { text = 'quote " backslash \\ newline \n' }
assert(vim.deep_equal(assert(rpc('tools/call', { name = 'echo', arguments = arguments })).structuredContent, arguments))
local _, expired = rpc('tools/call', { name = 'echo', arguments = { expire = true } })
assert(client.closed and expired:find('expired'))
connect()
live = false
wait(function() return seen.delete end)
assert(client.closed)

-- The main chat uses the same approved discovery and native-tool dispatch for remote servers.
live, seen.initialized, seen.delete = true, nil, nil
local state = mcp.new(config, vim.fn.getcwd(), function() return live end)
local approvals = 0
require('codeit.tools.approval.prompt').show = function(body, _, choose)
  assert(body:find(url .. '/mcp', 1, true) and not body:find('test-token', 1, true), body)
  approvals = approvals + 1
  choose('once')
end
local function execute(name, args)
  local _, advertised = mcp.specs(state)
  local output
  require('codeit.tools').execute(name, args, nil, function(value) output = value end, function() return live end,
    { mcp_state = state, mcp_advertised = advertised })
  return wait(function() return output end)
end
-- Ignore the fixture's first list-change notification only for this dispatch test.
seen.no_change = true
assert(execute(mcp.discovery_name, { server = 'sample', tool = 'echo' }):find('Activated'))
local specs = mcp.specs(state)
assert(vim.deep_equal(vim.json.decode(execute(specs[2]['function'].name, arguments)).structuredContent, arguments))
assert(approvals == 2)
live = false
wait(function() return seen.delete end)

local function search(cursor)
  local result, err, next_cursor
  registry.search({ url = url, bearer_token_env = 'TEST_MCP_TOKEN' }, 'a &b', cursor,
    function(value, failure, next_page) result, err, next_cursor = value, failure, next_page end)
  wait(function() return result or err end)
  return assert(result, err), next_cursor
end
local page, cursor = search()
assert(#page == 1 and page[1].name == 'test/first' and cursor == 'x+y=')
assert(search(cursor)[1].name == 'test/second')
local remotes = registry.remotes(page[1])
assert(#remotes == 1)
assert(not registry.install(config, 'invalid', { url = url }, nil))
assert(registry.install(config, 'installed', { url = remotes[1].url, bearer_token_env = 'TEST_MCP_TOKEN' }, '/workspace'))
assert(not registry.install(config, 'installed', { url = remotes[1].url }, nil))
assert(not registry.merge(config, '/other').servers.installed)
assert(registry.merge(config, '/workspace').servers.installed.bearer_token_env == 'TEST_MCP_TOKEN')
local saved = table.concat(vim.fn.readfile(vim.fn.stdpath('data') .. '/codeit/mcp-installs.json'), '\n')
assert(saved:find('TEST_MCP_TOKEN', 1, true) and not saved:find('test-token', 1, true))
assert(not registry.install(config, 'literal', { url = remotes[1].url, headers = { Authorization = 'secret' } }))
local selections = { 1, 3, 1, 3, 2 }
vim.ui.select = function(items, opts, cb)
  local index = table.remove(selections, 1)
  assert(index and items[index], opts.prompt)
  cb(items[index], index)
end
vim.ui.input = function(opts, cb)
  assert(opts.prompt:find('environment variable', 1, true))
  cb('TEST_MCP_TOKEN')
end
local registry_id = 'test-first-' .. vim.fn.sha256('test/first\n' .. remotes[1].url):sub(1, 10)
registry.browse({ local_test = { url = url, bearer_token_env = 'TEST_MCP_TOKEN' } }, config, 'a &b')
wait(function() return registry.merge(config, '/other').servers[registry_id] end)
assert(#selections == 0)
selections = { 2, 2 }
registry.manage()
assert(not registry.merge(config, '/other').servers[registry_id])
for _, socket in ipairs(clients) do if not socket:is_closing() then socket:close() end end
server:close()
