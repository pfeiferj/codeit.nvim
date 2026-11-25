vim.opt.runtimepath:prepend(vim.fn.getcwd())
local http = require('codeit.tools.mcp_http')
local oauth = require('codeit.tools.mcp_oauth')
local remote = require('codeit.tools.mcp_remote')
local resource = 'https://mcp.example.test/api/mcp'
local issuer = 'https://auth.example.test/tenant'
local token_endpoint = issuer .. '/oauth2/token'
local advertised_issuers = { issuer }
local metadata = 'https://mcp.example.test/metadata'
local function parse(value)
  local result = {}
  local function decode(text) return (text:gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end)) end
  for key, field in value:gmatch('([^&=]+)=([^&]*)') do result[decode(key)] = decode(field) end
  return result
end
local registrations, launches, refreshes, tool_calls = 0, 0, 0, 0
local choice, accepted, allow_tools = 'Open browser', 'first-token', true
local redirect, auth_query, bad_callback_status
local http_requests = {}
http.request = function(method, url, headers, body, _, done)
  http_requests[#http_requests + 1] = { url = url, method = method }
  local function reply(status, result, response_headers)
    vim.schedule(function()
      done({ status = status, headers = response_headers or {}, body = result and vim.json.encode(result) or '' })
    end)
  end
  if url == resource then
    if headers.Authorization ~= 'Bearer ' .. accepted then
      return reply(401, nil, { ['www-authenticate'] = 'Bearer resource_metadata="' .. metadata .. '", scope="read notes"' })
    end
    local result = { jsonrpc = '2.0', id = body.id }
    if body.method == 'initialize' then
      result.result = { protocolVersion = '2025-06-18', capabilities = { tools = vim.empty_dict() } }
    elseif body.method == 'notifications/initialized' then
      return reply(202)
    else
      assert(body.method == 'tools/call')
      tool_calls = tool_calls + 1
      if not allow_tools then return reply(401) end
      result.result = { content = { { type = 'text', text = 'ok' } } }
    end
    return reply(200, result)
  end
  assert(headers.Authorization == nil, 'credentials must not be forwarded to discovery or issuer endpoints')
  if url == metadata then
    return reply(200, { resource = resource, authorization_servers = advertised_issuers })
  elseif url == 'https://auth.example.test/.well-known/oauth-authorization-server/tenant' then
    return reply(200, { issuer = issuer, authorization_endpoint = issuer .. '/authorize', token_endpoint = token_endpoint,
      registration_endpoint = issuer .. '/register', code_challenge_methods_supported = { 'S256' },
      authorization_response_iss_parameter_supported = true })
  elseif url == issuer .. '/register' then
    assert(method == 'POST' and body.token_endpoint_auth_method == 'none')
    registrations = registrations + 1
    redirect = body.redirect_uris[1]
    return reply(201, { client_id = 'registered-id', token_endpoint_auth_method = 'none' })
  elseif url == token_endpoint then
    assert(headers['Content-Type'] == 'application/x-www-form-urlencoded')
    assert(type(body) == 'string')
    local fields = parse(body)
    assert(fields.resource == resource)
    if fields.grant_type == 'refresh_token' then
      assert(fields.refresh_token == 'test-refresh' and fields.client_id == 'registered-id')
      refreshes = refreshes + 1
      return reply(200, { access_token = accepted, token_type = 'bearer' })
    end
    assert(fields.code == 'valid+code' and fields.client_id == auth_query.client_id and fields.redirect_uri == auth_query.redirect_uri)
    assert(fields.client_secret == (fields.client_id == 'registered-secret-id' and 'test+secret' or nil))
    local digest = vim.fn.sha256(fields.code_verifier):gsub('%x%x', function(pair) return string.char(tonumber(pair, 16)) end)
    local expected = vim.base64.encode(digest):gsub('%+', '-'):gsub('/', '_'):gsub('=+$', '')
    assert(auth_query.code_challenge == expected and fields.code_verifier ~= auth_query.state)
    return reply(200, { access_token = accepted, refresh_token = 'test-refresh', token_type = 'Bearer', expires_in = 3600 })
  end
  error('Unexpected OAuth request ' .. url)
end
vim.ui.select = function(_, opts, done)
  assert(opts.prompt:find('https://auth.example.test', 1, true))
  done(choice)
end
local expected_redirect, forwarded_port, callback_ca, callback_path
vim.ui.open = function(url)
  assert(url:find(issuer .. '/authorize?', 1, true) == 1)
  launches = launches + 1
  auth_query = parse(url:match('%?(.*)$'))
  assert(auth_query.response_type == 'code' and auth_query.code_challenge_method == 'S256')
  assert(auth_query.scope == 'read notes' and auth_query.resource == resource)
  assert(#auth_query.state >= 32)
  if expected_redirect then assert(auth_query.redirect_uri == expected_redirect, auth_query.redirect_uri)
  else assert(auth_query.redirect_uri:match('^http://127%.0%.0%.1:%d+/$')) end
  if auth_query.client_id == 'registered-id' then assert(auth_query.redirect_uri == redirect) end
  local curl = { 'curl', '--disable', '--silent', '--noproxy', '*', '--max-time', '2', '--write-out', '%{http_code}' }
  if forwarded_port then
    local authority = auth_query.redirect_uri:match('^https?://([^/]+)/')
    vim.list_extend(curl, { '--connect-to', authority .. ':127.0.0.1:' .. forwarded_port })
  end
  if auth_query.redirect_uri:match('^https://') then
    vim.list_extend(curl, callback_ca and { '--cacert', callback_ca } or { '--insecure' })
  end
  local function callback(query, done)
    local target = auth_query.redirect_uri
    if callback_path then target = assert(target:match('^https?://[^/]+')) .. callback_path end
    local argv = vim.list_extend(vim.deepcopy(curl), { '--', target .. '?' .. query })
    return vim.system(argv, { text = true }, done and vim.schedule_wrap(done) or nil)
  end
  return callback('state=forged&code=invalid', function(result)
    bad_callback_status = result.stdout:sub(-3)
    assert(bad_callback_status == '400')
    callback('state=' .. auth_query.state .. '&iss=https%3A%2F%2Fwrong.example&code=forged', function(mismatch)
      assert(mismatch.stdout:sub(-3) == '400')
      callback('state=' .. auth_query.state .. '&iss=https%3A%2F%2Fauth.example.test%2Ftenant&code=valid%2Bcode')
    end)
  end)
end
local function wait(read)
  assert(vim.wait(5000, function() return read() ~= nil end), 'OAuth operation timed out')
  return read()
end
local function connect(server, cache)
  local client, err
  remote.start(server, nil, function() return true end, function(value, failure) client, err = value, failure end, cache)
  wait(function() return client or err end)
  return client, err
end

local setup = require('codeit.tools.mcp').configure
assert(not pcall(setup, { servers = { no_tls = { url = 'http://mcp.example.test', oauth = true } } }))
assert(not pcall(setup, { servers = { duplicate = { url = resource, oauth = true, bearer_token_env = 'TOKEN' } } }))
local server = setup({ servers = { demo = { url = resource, oauth = true } } }).servers.demo
local cache = {}
local client = assert(connect(server, cache))
assert(bad_callback_status == '400' and launches == 1 and registrations == 1 and oauth.token(server, cache) == accepted)
client.close()
assert(connect(server, cache)).close()
assert(launches == 1 and refreshes == 0)
accepted = 'next-token'
client = assert(connect(server, cache))
assert(refreshes == 1 and launches == 1 and oauth.token(server, cache) == accepted)
allow_tools = false
local failure
client.request('tools/call', { name = 'echo' }, function(_, err) failure = err end)
assert(wait(function() return failure end):find('rediscover'))
assert(tool_calls == 1 and oauth.token(server, cache) == nil and client.closed)

local fixed = setup({ servers = { demo = { url = resource, oauth = { client_id = 'public-id' } } } }).servers.demo
choice = 'Cancel'
local rejected, err = connect(fixed, {})
assert(not rejected and err:find('cancelled') and launches == 1)
choice = 'Open browser'
assert(connect(fixed, {})).close()
assert(launches == 2 and registrations == 1 and auth_query.client_id == 'public-id')

assert(not pcall(setup, { servers = { demo = { url = resource,
  oauth = { client_id = 'registered-secret-id', client_secret_env = 'MCP_TEST_SECRET' } } } }))
local confidential = setup({ servers = { demo = { url = resource, oauth = { client_id = 'registered-secret-id',
  client_secret_env = 'MCP_TEST_SECRET', issuer = issuer } } } }).servers.demo
vim.env.MCP_TEST_SECRET = 'test+secret'
assert(confidential.oauth.token_url == token_endpoint)
assert(connect(confidential, {})).close()
assert(launches == 3 and registrations == 1 and auth_query.client_id == 'registered-secret-id')

local pinned = setup({ servers = { demo = { url = resource, oauth = { client_id = 'public-id',
  resource = resource, token_url = issuer .. '/different-token' } } } }).servers.demo
local pinned_client, pinned_error = connect(pinned, {})
assert(not pinned_client and pinned_error:find('token_url', 1, true) and launches == 3)
assert(pinned.oauth.issuer == nil)

advertised_issuers = { 'https://other.example.test', issuer }
local inferred = setup({ servers = { demo = { url = resource, oauth = { client_id = 'public-id',
  resource = resource, token_url = token_endpoint } } } }).servers.demo
assert(inferred.oauth.issuer == issuer)
assert(connect(inferred, {})).close()
assert(launches == 4 and auth_query.client_id == 'public-id')
advertised_issuers = { issuer }

local slash_issuer = oauth.configure({ issuer = issuer .. '/' }, resource)
assert(slash_issuer.issuer == issuer .. '/' and slash_issuer.token_url == token_endpoint)
local queried_token = oauth.configure({ token_url = token_endpoint .. '?mode=test' }, resource)
assert(queried_token.issuer == issuer and queried_token.token_url == token_endpoint .. '?mode=test')
local explicit = oauth.configure({ issuer = issuer, token_url = issuer .. '/custom' }, resource)
assert(explicit.issuer == issuer and explicit.token_url == issuer .. '/custom')
assert(not pcall(oauth.configure, { client_id = 'public-id', client_secret_env = 'MCP_TEST_SECRET',
  token_url = token_endpoint }, resource))
for _, host in ipairs({ 'localhost', 'LOCALHOST', '127.0.0.0', '127.0.0.2', '127.255.255.255' }) do
  local url = 'http://' .. host .. ':8765/callback'
  assert(oauth.configure({ redirect_url = url }, resource).redirect_url == url)
  local tls_url = url:gsub('^http:', 'https:')
  assert(oauth.configure({ redirect_url = tls_url }, resource).redirect_url == tls_url)
end
for _, url in ipairs({
  'https://example.test:8765/callback', 'https://localhost/callback', 'http://localhost:08765/callback',
  'http://localhost:8765/../callback', 'http://localhost:8765/callback?query=yes',
  'http://localhost.example.test:8765/callback', 'http://localhost.:8765/callback',
  'http://localhost@example.test:8765/callback', 'http://128.0.0.1:8765/callback',
  'http://127.256.0.1:8765/callback', 'http://127.00.0.1:8765/callback',
  'http://127.1:8765/callback', 'http://[::1]:8765/callback',
}) do
  local ok, err = pcall(oauth.configure, { redirect_url = url }, resource)
  assert(not ok and err:find(url, 1, true), tostring(err))
end

local listen = require('codeit.tools.mcp_oauth_callback').listen
local function active() return true end
local function unexpected() error('unexpected OAuth callback') end
local preferred = 'http://127.0.0.1:33418/'
local probe = assert(vim.uv.new_tcp())
local available = probe:bind('127.0.0.1', 33418) and probe:listen(1, unexpected)
local probe_closed = false
probe:close(function() probe_closed = true end)
assert(vim.wait(1000, function() return probe_closed end))
local first, close_first = listen(nil, 'first', active, unexpected)
assert(first, close_first)
if available then assert(first == preferred, first) end
local second, close_second = listen(nil, 'second', active, unexpected)
assert(second and second ~= first and second ~= preferred, second or close_second)
local busy_port = tonumber(first:match(':(%d+)/$'))
local fixed_redirect, fixed_error = listen(busy_port, 'fixed', active, unexpected)
assert(fixed_redirect == nil and fixed_error:find('Could not listen', 1, true))
close_second()
close_first()

local received
local custom, close_custom = listen(nil, 'custom-state', active, function(code) received = code end, nil, false, '/corporate/callback')
assert(custom and custom:match('/corporate/callback$'), close_custom)
local function browser_get(target, state)
  local result
  vim.system({ 'curl', '--disable', '--silent', '--noproxy', '*', '--max-time', '2', '--write-out', '%{http_code}', '--',
    target .. '?state=' .. state .. '&code=ok' }, { text = true }, function(value) result = value end)
  return wait(function() return result end).stdout:sub(-3)
end
local root = custom:gsub('/corporate/callback$', '/')
assert(browser_get(root, 'forged') == '400' and received == nil)
assert(browser_get(root, 'custom-state') == '200' and wait(function() return received end) == 'ok')

expected_redirect = custom
local function sign_in_with_redirect(url, port)
  local configured = setup({ servers = { demo = { url = resource, oauth = {
    client_id = 'public-id', redirect_url = url, redirect_port = port,
  } } } }).servers.demo
  local client, err = connect(configured, {})
  assert(client, err).close()
end
sign_in_with_redirect(custom)
for _, host in ipairs({ 'localhost', '127.0.0.2' }) do
  expected_redirect = custom:gsub('127%.0%.0%.1', host)
  sign_in_with_redirect(expected_redirect)
end
forwarded_port = custom:match(':(%d+)/')
for _, host in ipairs({ '127.0.0.1', 'localhost' }) do
  expected_redirect = 'http://' .. host .. ':1/corporate/callback'
  sign_in_with_redirect(expected_redirect, tonumber(forwarded_port))
end

vim.env.CODEIT_MCP_OAUTH_TLS_CERT = nil
vim.env.CODEIT_MCP_OAUTH_TLS_KEY = nil
expected_redirect = 'https://localhost:' .. forwarded_port .. '/redirect'
forwarded_port = nil
callback_path = '/auth/blah'
sign_in_with_redirect(expected_redirect)
callback_path = nil

local cert_dir = vim.fn.stdpath('state') .. '/tls-test'
vim.fn.mkdir(cert_dir, 'p', 448)
local cert, key = cert_dir .. '/cert.pem', cert_dir .. '/key.pem'
local generated = vim.system({ 'openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
  '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost', '-keyout', key, '-out', cert }):wait(5000)
assert(generated.code == 0, generated.stderr)
vim.env.CODEIT_MCP_OAUTH_TLS_CERT = cert
vim.env.CODEIT_MCP_OAUTH_TLS_KEY = key
callback_ca = cert
sign_in_with_redirect(expected_redirect)

vim.env.CODEIT_MCP_OAUTH_TLS_KEY = nil
local before = launches
local partial = setup({ servers = { demo = { url = resource, oauth = {
  client_id = 'public-id', redirect_url = expected_redirect,
} } } }).servers.demo
local partial_client, partial_error = connect(partial, {})
assert(not partial_client and partial_error:find('Set both', 1, true) and launches == before, partial_error)
