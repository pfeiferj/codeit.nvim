local M = {}
local http = require('codeit.tools.mcp_http')

local function split(url)
  return url:match('^(https?://[^/?]+)([^?]*)')
end

function M.secure_url(url)
  if not http.url(url) then return false end
  local origin = split(url)
  return origin:sub(1, 8) == 'https://' or origin == 'http://127.0.0.1' or origin:match('^http://127%.0%.0%.1:%d+$') ~= nil
end

function M.configure(value, url)
  if value == nil or value == false then return nil end
  if value == true then value = {} end
  if type(value) ~= 'table' or not M.secure_url(url) then error('codeit: MCP OAuth needs an HTTPS or loopback remote URL') end
  local id, scopes, port = value.client_id, value.scopes, value.redirect_port
  if id ~= nil and (type(id) ~= 'string' or id == '' or #id > 2048 or id:find('%c')) then
    error('codeit: invalid MCP OAuth client_id')
  end
  if port ~= nil and (type(port) ~= 'number' or port < 1 or port > 65535 or port % 1 ~= 0) then
    error('codeit: invalid MCP OAuth redirect_port')
  end
  if scopes ~= nil then
    if not vim.islist(scopes) or #scopes > 32 then error('codeit: invalid MCP OAuth scopes') end
    for _, scope in ipairs(scopes) do
      if type(scope) ~= 'string' or scope == '' or #scope > 128 or scope:find('[%s%c"\\]') then
        error('codeit: invalid MCP OAuth scope')
      end
    end
  end
  local issuer, secret_env = value.issuer, value.client_secret_env
  if issuer ~= nil and (not M.secure_url(issuer) or issuer:find('?', 1, true)) then
    error('codeit: invalid MCP OAuth issuer')
  end
  if secret_env ~= nil and (not http.env_name(secret_env) or not id or not issuer or issuer:sub(1, 8) ~= 'https://') then
    error('codeit: MCP OAuth client_secret_env requires a client_id and pinned HTTPS issuer')
  end
  local resource, token_url, redirect_url = value.resource, value.token_url, value.redirect_url
  for field, endpoint in pairs({ resource = resource, token_url = token_url }) do
    if not M.secure_url(endpoint) then error('codeit: invalid MCP OAuth ' .. field) end
  end
  if redirect_url ~= nil then
    local fixed_port, path
    if type(redirect_url) == 'string' then fixed_port, path = redirect_url:match('^http://127%.0%.0%.1:(%d+)(/[%w_./-]*)$') end
    local number = tonumber(fixed_port)
    if not number or number < 1 or number > 65535 or tostring(number) ~= fixed_port or #path > 256
      or path:find('//', 1, true) or (path .. '/'):find('/%.%.?/') then
      error('codeit: invalid MCP OAuth redirect_url (expected a fixed loopback URL)')
    end
  end
  return { client_id = id, scopes = vim.deepcopy(scopes), redirect_port = port, issuer = issuer, client_secret_env = secret_env,
    resource = resource, token_url = token_url, redirect_url = redirect_url }
end

local function key(server)
  local config = server.oauth
  return vim.json.encode({ server.url, config.client_id or '', config.scopes or {}, config.redirect_port or 0,
    config.issuer or '', config.client_secret_env or '', config.resource or '', config.token_url or '', config.redirect_url or '' })
end

function M.token(server, cache)
  local entry = cache[key(server)]
  if entry and entry.token and (not entry.expires or entry.expires > os.time() + 5) then return entry.token end
end

function M.invalidate(server, cache, token)
  local entry = cache[key(server)]
  if entry and entry.token == token then entry.token = nil end
end

local function escape(text)
  return (text:gsub('[^%w_.~-]', function(char) return ('%%%02X'):format(char:byte()) end))
end

local function form(values)
  local parts = {}
  for name, value in pairs(values) do parts[#parts + 1] = escape(name) .. '=' .. escape(value) end
  return table.concat(parts, '&')
end

local function challenge_param(challenge, name)
  if not challenge:lower():match('%f[%w]bearer%f[%W]') then return end
  return challenge:match(name .. '%s*=%s*"([^"]+)"') or challenge:match(name .. '%s*=%s*([^%s,]+)')
end

local function token_chars(value)
  return type(value) == 'string' and #value > 0 and #value <= 8192 and not value:find('[%s%c]')
end

local function json(method, url, body, active, callback)
  if not active() then return end
  local headers = { Accept = 'application/json' }
  if body then headers['Content-Type'] = type(body) == 'string' and 'application/x-www-form-urlencoded' or 'application/json' end
  http.request(method, url, headers, body, 15000, function(response, err)
    if not active() then return end
    if not response then return callback(nil, err) end
    if response.status < 200 or response.status >= 300 then return callback(nil, 'HTTP ' .. response.status) end
    local ok, result = pcall(vim.json.decode, response.body)
    if not ok or type(result) ~= 'table' or vim.islist(result) then return callback(nil, 'Invalid OAuth JSON response') end
    callback(result)
  end)
end

local function first_metadata(urls, active, validate, done)
  local seen = {}
  local function next_url(index)
    local url = urls[index]
    if not url then return done(nil) end
    if seen[url] or not M.secure_url(url) then return next_url(index + 1) end
    seen[url] = true
    json('GET', url, nil, active, function(value)
      if value and validate(value) then done(value) else next_url(index + 1) end
    end)
  end
  next_url(1)
end

local function discover(server, challenge, active, done)
  local origin, path = split(server.url)
  local metadata_url = challenge_param(challenge, 'resource_metadata')
  local urls = metadata_url and { metadata_url } or { origin .. '/.well-known/oauth-protected-resource' .. path,
    origin .. '/.well-known/oauth-protected-resource' }
  first_metadata(urls, active, function(value)
    -- A configured resource pin still has to agree with the endpoint's discovery metadata.
    return M.secure_url(value.resource) and value.resource:gsub('/+$', '') == (server.oauth.resource or server.url):gsub('/+$', '')
      and vim.islist(value.authorization_servers) and #value.authorization_servers > 0
  end, function(resource)
    if not resource then return done(nil, 'Could not discover OAuth protected-resource metadata for this MCP endpoint') end
    local issuer
    for _, candidate in ipairs(resource.authorization_servers) do
      if (not server.oauth.issuer or candidate == server.oauth.issuer) and M.secure_url(candidate)
        and not candidate:find('?', 1, true) then issuer = candidate; break end
    end
    if not issuer then return done(nil, 'MCP resource did not advertise a usable OAuth issuer') end
    local base, suffix = split(issuer)
    suffix = suffix:gsub('/$', '')
    first_metadata({ base .. '/.well-known/oauth-authorization-server' .. suffix,
      base .. '/.well-known/openid-configuration' .. suffix, base .. suffix .. '/.well-known/openid-configuration' }, active,
      function(value)
        return value.issuer == issuer and M.secure_url(value.authorization_endpoint) and M.secure_url(value.token_endpoint)
      end, function(metadata)
        if not metadata then return done(nil, 'Could not discover metadata for the MCP OAuth issuer') end
        if not vim.islist(metadata.code_challenge_methods_supported)
          or not vim.tbl_contains(metadata.code_challenge_methods_supported, 'S256') then
          return done(nil, 'MCP OAuth issuer does not advertise PKCE S256')
        end
        if server.oauth.token_url and server.oauth.token_url ~= metadata.token_endpoint then
          return done(nil, 'Discovered MCP OAuth token endpoint does not match the configured token_url')
        end
        if server.oauth.client_secret_env and split(metadata.token_endpoint) ~= base then
          return done(nil, 'MCP OAuth token endpoint must share the pinned issuer origin when using a client secret')
        end
        done({ resource = resource.resource, metadata = metadata, secret_env = server.oauth.client_secret_env,
          scope = challenge_param(challenge, 'scope')
          or vim.islist(resource.scopes_supported) and table.concat(vim.tbl_filter(function(scope)
            return type(scope) == 'string' and not scope:find('%c')
          end, resource.scopes_supported), ' ') or nil })
      end)
  end)
end

local function exchange(context, data, previous, active, done)
  data.resource, data.client_id = context.resource, context.client_id
  if context.secret_env then
    local secret = vim.env[context.secret_env]
    if not secret or secret == '' then return done(nil, 'Set $' .. context.secret_env .. ' for MCP OAuth') end
    data.client_secret = secret
  end
  json('POST', context.metadata.token_endpoint, form(data), active, function(result, err)
    if not result then return done(nil, 'MCP OAuth token exchange failed: ' .. err) end
    if not token_chars(result.access_token) or type(result.token_type) ~= 'string' or result.token_type:lower() ~= 'bearer' then
      return done(nil, 'MCP OAuth issuer did not return a valid bearer token')
    end
    local refresh = token_chars(result.refresh_token) and result.refresh_token or previous
    local expires = tonumber(result.expires_in)
    done({ token = result.access_token, refresh = refresh, context = context,
      expires = expires and expires >= 0 and expires < math.huge and os.time() + expires or nil })
  end)
end

local function random_hex()
  local bytes = vim.uv.random(32)
  if bytes then return (bytes:gsub('.', function(char) return ('%02x'):format(char:byte()) end)) end
end

function M.login(server, challenge, cache, active, done)
  if server.oauth.client_secret_env and (vim.env[server.oauth.client_secret_env] or '') == '' then
    return done(nil, 'Set $' .. server.oauth.client_secret_env .. ' for MCP OAuth')
  end
  local cache_key = key(server)
  local function store(entry)
    cache[cache_key] = entry
    done(entry.token)
  end
  local function browser()
    discover(server, challenge, active, function(context, err)
      if not context then return done(nil, err) end
      if server.oauth.scopes then context.scope = table.concat(server.oauth.scopes, ' ') end
      if context.scope == '' then context.scope = nil end
      local auth_origin = split(context.metadata.authorization_endpoint)
      local token_origin = split(context.metadata.token_endpoint)
      vim.ui.select({ 'Open browser', 'Cancel' }, { prompt = 'MCP OAuth for ' .. server.url .. ' via ' .. auth_origin
        .. (token_origin ~= auth_origin and (' (tokens: ' .. token_origin .. ')') or '') }, function(choice)
        if not active() then return end
        if choice ~= 'Open browser' then return done(nil, 'MCP OAuth sign-in cancelled') end
        local state, verifier = random_hex(), random_hex()
        if not state or not verifier then return done(nil, 'Could not generate secure OAuth randomness') end
        local digest = vim.fn.sha256(verifier):gsub('%x%x', function(pair) return string.char(tonumber(pair, 16)) end)
        local pkce = vim.base64.encode(digest):gsub('%+', '-'):gsub('/', '_'):gsub('=+$', '')
        local redirect, stop
        local function use_code(code, failure)
          if not code then return done(nil, failure) end
          exchange(context, { grant_type = 'authorization_code', code = code, code_verifier = verifier,
            redirect_uri = redirect }, nil, active, function(entry, token_err)
            if entry then store(entry) else done(nil, token_err) end
          end)
        end
        local advertised_port, path
        if server.oauth.redirect_url then
          advertised_port, path = server.oauth.redirect_url:match(':(%d+)(/.*)$')
        end
        local port = server.oauth.redirect_port or tonumber(advertised_port)
        local listener_url
        listener_url, stop = require('codeit.tools.mcp_oauth_callback').listen(port, state, active, use_code,
          context.metadata.issuer, context.metadata.authorization_response_iss_parameter_supported == true, path, advertised_port)
        if not listener_url then return done(nil, stop) end
        redirect = server.oauth.redirect_url or listener_url
        local function launch(client_id)
          context.client_id = client_id
          local endpoint = context.metadata.authorization_endpoint
          local url = endpoint .. (endpoint:find('?', 1, true) and '&' or '?') .. form({ response_type = 'code',
            client_id = client_id, redirect_uri = redirect, state = state, code_challenge = pkce,
            code_challenge_method = 'S256', resource = context.resource, scope = context.scope })
          local ok, process = pcall(vim.ui.open, url)
          if not ok or not process then stop(); done(nil, 'Could not open a browser for MCP OAuth') end
        end
        if server.oauth.client_id then return launch(server.oauth.client_id) end
        local registration = context.metadata.registration_endpoint
        if not M.secure_url(registration) then
          stop()
          return done(nil, 'MCP OAuth issuer does not offer dynamic registration; configure oauth.client_id')
        end
        json('POST', registration, { client_name = 'Codeit.nvim', redirect_uris = { redirect },
          token_endpoint_auth_method = 'none', grant_types = { 'authorization_code', 'refresh_token' }, response_types = { 'code' } },
          active, function(client, registration_err)
            if not client or not token_chars(client.client_id)
              or client.token_endpoint_auth_method and client.token_endpoint_auth_method ~= 'none' then
              stop()
              return done(nil, 'MCP OAuth public-client registration failed' .. (registration_err and ': ' .. registration_err or ''))
            end
            launch(client.client_id)
          end)
      end)
    end)
  end
  local existing = cache[cache_key]
  local requested_scope = challenge_param(challenge, 'scope')
  if existing and existing.refresh and (not requested_scope or requested_scope == existing.context.scope) then
    return exchange(existing.context, { grant_type = 'refresh_token', refresh_token = existing.refresh }, existing.refresh,
      active, function(entry) if entry then store(entry) else cache[cache_key] = nil; browser() end end)
  end
  browser()
end

return M
