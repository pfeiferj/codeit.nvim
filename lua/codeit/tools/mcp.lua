local M = { discovery_name = 'discover_mcp_tools' }
local prefix = 'mcp__'
local max_tools, page_size, max_active = 128, 20, 12
local utf8 = require('codeit.utf8')
local http = require('codeit.tools.mcp_http')

local function object(value)
  return type(value) == 'table' and (not vim.islist(value) or next(value) == nil)
end

local function text(value, limit)
  return type(value) == 'string' and #value > 0 and #value <= limit and not value:find('%z')
end

function M.configure(config)
  if config == nil then return { servers = {}, workspaces = {} } end
  local function check(valid, field)
    if not valid then error('codeit: invalid mcp.' .. field) end
  end
  check(object(config), 'configuration')
  local servers, workspaces = config.servers, config.workspaces
  if servers == nil then servers = {} end
  if workspaces == nil then workspaces = {} end
  check(object(servers), 'servers')
  check(object(workspaces), 'workspaces')
  local validated = { servers = {}, workspaces = {} }
  for id, server in pairs(servers) do
    check(text(id, 40) and id:match('^[%w_-]+$') and object(server), 'servers entry')
    local field = 'servers.' .. id
    local remote = server.url ~= nil
    check(remote and http.url(server.url) and not server.url:find('[{}]') and server.command == nil
      or not remote and text(server.command, 4096) and not server.command:find('%c'), field .. ' (set either a URL or a stdio command)')
    check(server.transport == nil or server.transport == (remote and 'streamable-http' or 'stdio'), field .. '.transport')
    check(remote and server.args == nil and server.env == nil or not remote and server.headers == nil
      and server.header_env == nil and server.bearer_token_env == nil, field .. ' (options must match transport)')
    check(server.bearer_token_env == nil or http.env_name(server.bearer_token_env), field .. '.bearer_token_env')
    for _, map in ipairs({ 'headers', 'header_env' }) do
      check(server[map] == nil or object(server[map]), field .. '.' .. map)
      local reserved = { accept = true, ['content-type'] = true, ['mcp-session-id'] = true,
        ['mcp-protocol-version'] = true, host = true, ['content-length'] = true, ['transfer-encoding'] = true }
      for key, value in pairs(server[map] or {}) do
        check(http.header(key) and not reserved[key:lower()] and (map == 'headers' and type(value) == 'string'
          and not value:find('%c') and #value <= 8192 or map == 'header_env' and http.env_name(value)), field .. '.' .. map)
      end
    end
    check(server.enabled == nil or type(server.enabled) == 'boolean', field .. '.enabled')
    check(server.description == nil or text(server.description, 200) and not server.description:find('%c'), field .. '.description')
    check(server.args == nil or vim.islist(server.args), field .. '.args')
    check(server.env == nil or object(server.env), field .. '.env')
    for _, arg in ipairs(server.args or {}) do
      check(arg == '' or text(arg, 4096), field .. '.args')
    end
    for key, value in pairs(server.env or {}) do
      check(text(key, 512) and not key:find('=', 1, true) and type(value) == 'string' and not value:find('%z'), field .. '.env')
    end
    local oauth = require('codeit.tools.mcp_oauth').configure(server.oauth, server.url)
    if oauth then
      check(not server.bearer_token_env, field .. ' (OAuth cannot be combined with a bearer token)')
      for _, map in ipairs({ 'headers', 'header_env' }) do
        for key in pairs(server[map] or {}) do
          check(key:lower() ~= 'authorization', field .. ' (OAuth sets the Authorization header)')
        end
      end
    end
    local timeout = server.timeout_ms == nil and 30000 or server.timeout_ms
    check(type(timeout) == 'number' and timeout >= 100 and timeout <= 300000 and timeout % 1 == 0, field .. '.timeout_ms')
    validated.servers[id] = { command = server.command, args = not remote and vim.deepcopy(server.args or {}) or nil,
      url = server.url, headers = vim.deepcopy(server.headers), header_env = vim.deepcopy(server.header_env),
      bearer_token_env = server.bearer_token_env, oauth = oauth, env = vim.deepcopy(server.env), enabled = server.enabled ~= false,
      description = server.description, timeout_ms = timeout }
  end
  for path, overrides in pairs(workspaces) do
    check(text(path, 4096) and object(overrides), 'workspaces entry')
    path = vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
    path = vim.uv.fs_realpath(path) or path
    check(not validated.workspaces[path], 'workspaces duplicate path')
    for id, enabled in pairs(overrides) do
      check(text(id, 40) and id:match('^[%w_-]+$') and type(enabled) == 'boolean',
        'workspaces overrides must map server IDs to booleans')
    end
    validated.workspaces[path] = vim.deepcopy(overrides)
  end
  return validated
end

function M.new(config, workspace, active, oauth_cache)
  return { config = config, workspace = workspace, active = active, connections = {}, tools = {}, oauth_cache = oauth_cache }
end

local function server_for(state, id)
  local server = state.config.servers[id]
  local overrides = state.config.workspaces[state.workspace] or {}
  if server and (overrides[id] == true or overrides[id] == nil and server.enabled) then return server end
end

function M.is_tool(name)
  return type(name) == 'string' and (name == M.discovery_name or name:sub(1, #prefix) == prefix)
end

function M.specs(state)
  local specs, advertised = {}, {}
  if not state or not state.config then return specs, advertised end
  local ids, descriptions = {}, {}
  for _, id in ipairs(vim.tbl_keys(state.config.servers)) do
    if server_for(state, id) then ids[#ids + 1] = id end
  end
  if #ids == 0 then return specs, advertised end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local description = state.config.servers[id].description
    if description then descriptions[#descriptions + 1] = id .. ': ' .. description end
  end
  local spec = { type = 'function', ['function'] = {
    name = M.discovery_name,
    description = 'Discover tools on an enabled MCP server. Omit tool to list compact descriptions; provide an exact tool name to activate its native function on the next round. Activate only tools needed for the current turn.',
    parameters = { type = 'object', additionalProperties = false, required = { 'server' }, properties = {
      server = { type = 'string', enum = ids, description = table.concat(descriptions, '; ') },
      tool = { type = 'string', minLength = 1, maxLength = 128 },
      offset = { type = 'integer', minimum = 0, maximum = max_tools - 1, description = 'Continue listing from next_offset.' },
    } },
  } }
  specs[1], advertised[M.discovery_name] = spec, spec
  local names = vim.tbl_keys(state.tools)
  table.sort(names)
  for _, name in ipairs(names) do
    local entry = state.tools[name]
    if server_for(state, entry.server) and not entry.client.closed and entry.connection.catalog then
      specs[#specs + 1], advertised[name] = entry.spec, entry
    else
      state.tools[name] = nil
    end
  end
  return specs, advertised
end

function M.read_catalog(connection, done)
  if connection.catalog then return done(connection.catalog) end
  local catalog, seen, pages = {}, {}, 0
  local revision = connection.revision
  local function page(cursor)
    pages = pages + 1
    connection.client.request('tools/list', cursor and { cursor = cursor } or nil, function(result, err)
      if connection.revision ~= revision then return done(nil, 'MCP tool list changed; retry discovery') end
      if not result then return done(nil, err) end
      if not vim.islist(result.tools) then return done(nil, 'Invalid MCP tools/list response') end
      for _, tool in ipairs(result.tools) do
        if not object(tool) or not text(tool.name, 128) or tool.name:find('%c')
          or not object(tool.inputSchema) or tool.inputSchema.type ~= 'object' or seen[tool.name] then
          return done(nil, 'Invalid or duplicate MCP tool definition')
        end
        seen[tool.name] = true
        catalog[#catalog + 1] = tool
        if #catalog >= max_tools then break end
      end
      local next_cursor = result.nextCursor
      if #catalog < max_tools and next_cursor ~= nil then
        if not text(next_cursor, 4096) or next_cursor == cursor or pages >= 16 then
          return done(nil, 'Invalid or excessive MCP tool pagination')
        end
        return page(next_cursor)
      end
      connection.catalog = catalog
      connection.truncated = next_cursor ~= nil or #catalog >= max_tools
      done(catalog)
    end)
  end
  page()
end

local function discover(state, args, connection, done)
  M.read_catalog(connection, function(catalog, err)
    if not catalog then return done('Error: ' .. err) end
    if not args.tool then
      local offset, listing = args.offset or 0, {}
      for index = offset + 1, math.min(#catalog, offset + page_size) do
        local tool = catalog[index]
        listing[#listing + 1] = { name = tool.name, description = type(tool.description) == 'string'
          and utf8.prefix(tool.description, 180) or nil }
      end
      return done(vim.json.encode({ server = args.server, tools = listing,
        next_offset = offset + page_size < #catalog and offset + page_size or nil, truncated = connection.truncated }))
    end
    for _, tool in ipairs(catalog) do
      if tool.name == args.tool then
        local name = prefix .. args.server:sub(1, 16) .. '__' .. tool.name:gsub('[^%w_-]', '_'):sub(1, 22)
          .. '__' .. vim.fn.sha256(args.server .. '\n' .. tool.name):sub(1, 16)
        if not state.tools[name] and vim.tbl_count(state.tools) >= max_active then
          return done('Error: MCP turn has reached its active tool limit')
        end
        if #vim.json.encode(tool.inputSchema) > 16000 then return done('Error: MCP input schema exceeds the size limit') end
        local description = type(tool.description) == 'string' and utf8.prefix(tool.description, 1500) or ''
        local spec = { type = 'function', ['function'] = { name = name,
          description = 'MCP server ' .. args.server .. ', tool ' .. tool.name .. '. ' .. description,
          parameters = tool.inputSchema } }
        state.tools[name] = { spec = spec, server = args.server, name = tool.name, client = connection.client,
          connection = connection, revision = connection.revision }
        return done('Activated ' .. name .. '; call it as a native tool on the next round.')
      end
    end
    done('Error: tool not found in the MCP server catalog')
  end)
end

function M.execute(name, args, source, done, active, context, safe)
  local state = context and context.mcp_state
  local entry = state and context.mcp_advertised and context.mcp_advertised[name]
  if not entry or context.subagent_run or not state.active() then
    return done('Error: MCP tool was not advertised for this request')
  end
  local function approve(details, approval_args, action)
    local approval_context = vim.tbl_extend('force', context, { source_buffer = source, external_tool = details })
    require('codeit.tools.approval').request(name, approval_args, details, active, done, safe(function()
      if state.active() then action() end
    end), approval_context)
  end
  if name == M.discovery_name then
    local invalid = require('codeit.tools.validation').validate({ entry }, name, args)
    if invalid then return done('Error: ' .. invalid) end
    local server = server_for(state, args.server)
    if not server then return done('Error: MCP server is disabled in this workspace') end
    local connection = state.connections[args.server]
    if connection and not connection.client.closed then return discover(state, args, connection, done) end
    local details = server.url and ('Connect to MCP server ' .. args.server .. ' at `' .. server.url
      .. '`. The endpoint receives any configured HTTP headers.') or ('Start MCP server ' .. args.server .. ' (`' .. server.command
      .. '`) in this workspace. The process is not sandboxed.')
    approve(details, args, function()
      local transport = require(server.url and 'codeit.tools.mcp_remote' or 'codeit.tools.mcp_client')
      transport.start(server, state.workspace, state.active, function(client, err)
        if not client then return done('Error: ' .. err) end
        connection = { client = client, revision = 0 }
        state.connections[args.server] = connection
        client.on_list_changed = function()
          connection.catalog = nil
          connection.revision = connection.revision + 1
          for tool, activated in pairs(state.tools) do
            if activated.connection == connection then state.tools[tool] = nil end
          end
        end
        discover(state, args, connection, done)
      end, state.oauth_cache)
    end)
    return
  end
  local function current()
    return server_for(state, entry.server) and not entry.client.closed and entry.revision == entry.connection.revision
  end
  if not current() then return done('Error: MCP tool is no longer available; rediscover it') end
  if not object(args) then return done('Error: MCP tool arguments must be an object') end
  if next(args) == nil then args = vim.empty_dict() end
  if #vim.json.encode(args) > 20000 then return done('Error: MCP arguments exceed the size limit') end
  local endpoint = server_for(state, entry.server).url
  approve('Call MCP server ' .. entry.server .. (endpoint and ' at `' .. endpoint .. '`' or '')
    .. ', tool `' .. entry.name .. '`. The server receives these arguments.', args, function()
    if not current() then return done('Error: MCP tool changed while awaiting approval; rediscover it') end
    entry.client.request('tools/call', { name = entry.name, arguments = args }, function(result, err)
      if not result then return done('Error: ' .. err) end
      -- Keep protocol metadata such as _meta out of the model-visible result.
      local output = vim.json.encode({ content = result.content, structuredContent = result.structuredContent,
        isError = result.isError })
      if #output > 20000 then output = utf8.prefix(output, 20000) .. '\n[MCP result truncated]' end
      done((result.isError == true and 'Error: MCP tool returned an error\n' or '') .. output)
    end)
  end)
end

return M
