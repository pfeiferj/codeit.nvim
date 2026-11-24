local M = {}
local http = require('codeit.tools.mcp_http')
local utf8 = require('codeit.utf8')
local defaults = { github = { url = 'https://api.mcp.github.com' },
  official = { url = 'https://registry.modelcontextprotocol.io' } }

function M.configure(options)
  if options ~= nil and type(options) ~= 'table' then error('codeit: mcp.registries must be a table') end
  local registries = vim.deepcopy(defaults)
  for name, registry in pairs(options or {}) do
    if type(name) ~= 'string' or not name:match('^[%w_-]+$') then error('codeit: invalid MCP registry name') end
    if registry == false then registries[name] = nil
    else
      if type(registry) == 'string' then registry = { url = registry } end
      if type(registry) ~= 'table' or not http.url(registry.url) or registry.url:find('?', 1, true)
        or registry.bearer_token_env ~= nil and not http.env_name(registry.bearer_token_env) then
        error('codeit: invalid mcp.registries.' .. name)
      end
      registries[name] = { url = registry.url:gsub('/+$', ''), bearer_token_env = registry.bearer_token_env }
    end
  end
  return registries
end

local function escape(text)
  return (text:gsub('[^a-zA-Z0-9_.~-]', function(char) return ('%%%02X'):format(char:byte()) end))
end

local function label(value, limit)
  if type(value) == 'string' then return utf8.prefix(value:gsub('%c', ' '), limit) end
  return ''
end

function M.search(registry, query, cursor, done)
  local headers, err = http.headers(registry)
  if not headers then return done(nil, err) end
  headers.Accept = 'application/json'
  local base = registry.url
  if not base:match('/v0%.1$') then base = base .. '/v0.1' end
  local url = base .. '/servers?limit=12&version=latest'
    .. (query ~= '' and ('&search=' .. escape(query)) or '')
    .. (cursor and ('&cursor=' .. escape(cursor)) or '')
  http.request('GET', url, headers, nil, 20000, function(response, failure)
    if not response then return done(nil, failure) end
    if response.status ~= 200 then return done(nil, 'MCP registry returned HTTP ' .. response.status) end
    local ok, page = pcall(vim.json.decode, response.body)
    if not ok or type(page) ~= 'table' or not vim.islist(page.servers) then return done(nil, 'Invalid MCP registry response') end
    local entries = {}
    for _, result in ipairs(page.servers) do
      if type(result) == 'table' and type(result.server) == 'table' then
        local manifest = result.server
        local meta = type(result._meta) == 'table' and result._meta['io.modelcontextprotocol.registry/official']
        local status = type(meta) == 'table' and meta.status or manifest.status
        if label(manifest.name, 250) ~= '' and status ~= 'deleted' and status ~= 'deprecated' then
          entries[#entries + 1] = manifest
        end
      end
    end
    local next_cursor = type(page.metadata) == 'table' and page.metadata.nextCursor
    if type(next_cursor) ~= 'string' or #next_cursor > 512 or next_cursor == '' or next_cursor == cursor then next_cursor = nil end
    done(entries, nil, next_cursor)
  end)
end

function M.remotes(manifest)
  local remotes = {}
  if not vim.islist(manifest.remotes) then return remotes end
  for _, remote in ipairs(manifest.remotes) do
    if type(remote) == 'table' and remote.type == 'streamable-http' and http.url(remote.url)
      and remote.url:match('^https://') and not remote.url:find('[{}]') then
      remotes[#remotes + 1] = remote
    end
  end
  return remotes
end

local function path()
  return vim.fn.stdpath('data') .. '/codeit/mcp-installs.json'
end

local function load()
  local stat = vim.uv.fs_stat(path())
  if not stat then return {} end
  if stat.type ~= 'file' or stat.size > 1024 * 1024 then return nil, 'Invalid MCP installs file' end
  local ok, data = pcall(function() return vim.json.decode(table.concat(vim.fn.readfile(path()), '\n')) end)
  if not ok or type(data) ~= 'table' or vim.islist(data) then return nil, 'Invalid MCP installs file' end
  return data
end

local function save(entries)
  local filename = path()
  vim.fn.mkdir(vim.fs.dirname(filename), 'p')
  local fd, temp = vim.uv.fs_mkstemp(filename .. '.XXXXXX')
  if not fd then return nil, temp end
  local encoded = vim.json.encode(next(entries) and entries or vim.empty_dict()) .. '\n'
  local size, err = vim.uv.fs_write(fd, encoded, 0)
  vim.uv.fs_close(fd)
  local ok
  if size == #encoded then ok, err = vim.uv.fs_rename(temp, filename) end
  if not ok then vim.uv.fs_unlink(temp) end
  return ok, err or 'Could not write MCP installs'
end

function M.merge(config, workspace)
  local entries, err = load()
  if not entries then vim.notify('codeit: ' .. err, vim.log.levels.WARN); return config end
  local merged = { servers = vim.tbl_extend('force', {}, config.servers), workspaces = config.workspaces }
  for id, entry in pairs(entries) do
    if not merged.servers[id] and type(entry) == 'table' and (entry.workspace == nil or entry.workspace == workspace) then
      local server = entry.server
      if type(server) == 'table' and type(server.url) == 'string' and server.url:match('^https://') and server.command == nil then
        local ok, normalized = pcall(require('codeit.tools.mcp').configure, { servers = { [id] = server } })
        if ok then merged.servers[id] = normalized.servers[id] end
      end
    end
  end
  return merged
end

local function notify(message) vim.notify('codeit: ' .. message) end

function M.install(config, id, server, workspace)
  local ok, normalized = pcall(require('codeit.tools.mcp').configure, { servers = { [id] = server } })
  if not ok then return nil, normalized end
  local installed = normalized.servers[id]
  if not installed.url or not installed.url:match('^https://') then
    return nil, 'Registry installs require an HTTPS endpoint'
  end
  if installed.headers and next(installed.headers) then return nil, 'Registry installs require environment references for headers' end
  installed.headers = nil
  local entries, err = load()
  if not entries then return nil, err end
  if entries[id] or config.servers[id] then return nil, 'Server ID is already installed or configured: ' .. id end
  entries[id] = { server = installed, workspace = workspace }
  return save(entries)
end

local function configure_auth(remote, use_oauth, done)
  local config = { url = remote.url, header_env = {} }
  local headers = vim.islist(remote.headers) and remote.headers or {}
  if #headers > 32 then return notify('Too many registry header definitions') end
  local has_auth = false
  local function next_header(index)
    local header = headers[index]
    if not header then
      if use_oauth then
        return vim.ui.input({ prompt = 'Public OAuth client ID (blank for dynamic registration): ' }, function(value)
          if value then
            config.oauth = { client_id = value ~= '' and value or nil }
            done(config)
          end
        end)
      end
      if has_auth then return done(config) end
      return vim.ui.input({ prompt = 'Bearer token environment variable (blank for none): ' }, function(value)
        if not value then return end
        if value ~= '' and not http.env_name(value) then return notify('Invalid environment variable name') end
        config.bearer_token_env = value ~= '' and value or nil
        done(config)
      end)
    end
    if type(header) ~= 'table' or not http.header(header.name) then return notify('Invalid registry header definition') end
    local authorization = header.name:lower() == 'authorization'
    if use_oauth and authorization then return next_header(index + 1) end
    has_auth = has_auth or authorization
    local bearer = authorization and type(header.value) == 'string' and header.value:match('^[Bb]earer%s')
    local hint = bearer and 'Bearer token' or 'value'
    vim.ui.input({ prompt = header.name .. ' ' .. hint .. ' environment variable'
      .. (header.isRequired == true and ' (required): ' or ' (blank to skip): ') }, function(value)
      if not value then return end
      if value ~= '' and not http.env_name(value) or value == '' and header.isRequired == true then
        return notify('A valid environment variable name is required')
      end
      if value ~= '' then
        if bearer then config.bearer_token_env = value else config.header_env[header.name] = value end
      end
      next_header(index + 1)
    end)
  end
  next_header(1)
end

local function preview(server, oauth_cache)
  local ok, normalized = pcall(require('codeit.tools.mcp').configure, { servers = { preview = server } })
  if not ok then return notify(normalized) end
  require('codeit.tools.mcp_remote').start(normalized.servers.preview, nil, function() return true end, function(client, err)
    if not client then return notify(err) end
    local connection = { client = client, revision = 0 }
    require('codeit.tools.mcp').read_catalog(connection, function(catalog, failure)
      client.close()
      if not catalog then return notify(failure) end
      vim.ui.input({ prompt = 'Filter live tools by name or description (blank to browse): ' }, function(query)
        if not query then return end
        query = query:lower()
        local matches = vim.tbl_filter(function(tool)
          return (tool.name .. ' ' .. label(tool.description, 2000)):lower():find(query, 1, true) ~= nil
        end, catalog)
        if #matches == 0 then return notify('No matching MCP tools') end
        vim.ui.select(matches, { prompt = connection.truncated and 'MCP tools (catalog capped)' or 'MCP tools',
          format_item = function(tool) return tool.name .. ' — ' .. label(tool.description, 180) end }, function(tool)
          if tool then notify(tool.name .. ': ' .. label(tool.description, 1000)) end
        end)
      end)
    end)
  end, oauth_cache)
end

function M.browse(registries, config, initial_query, oauth_cache)
  local workspace = require('codeit.chat.storage').workspace()
  local names = vim.tbl_keys(registries)
  table.sort(names)
  vim.ui.select(names, { prompt = 'MCP registry' }, function(name)
    if not name then return end
    local list
    local function search()
      vim.ui.input({ prompt = 'Search MCP servers (blank to browse): ', default = initial_query }, function(query)
        if query then list(vim.trim(query)) end
      end)
    end
    list = function(query, cursor)
      if #query > 200 then return notify('MCP registry search is too long') end
      M.search(registries[name], query, cursor, function(entries, err, next_cursor)
        if not entries then return notify(err) end
        local choices = { { action = 'New search' } }
        if next_cursor then choices[#choices + 1] = { action = 'Next page' } end
        for _, manifest in ipairs(entries) do choices[#choices + 1] = { manifest = manifest } end
        vim.ui.select(choices, { prompt = #entries == 0 and 'No matching MCP servers' or ('MCP servers — ' .. name),
          format_item = function(item)
            return item.action or (label(item.manifest.name, 150) .. ' — ' .. label(item.manifest.description, 160))
          end }, function(item)
          if not item then return end
          if item.action == 'New search' then return search() end
          if item.action == 'Next page' then return list(query, next_cursor) end
          item = item.manifest
          local remotes = M.remotes(item)
          if #remotes == 0 then return notify('No compatible HTTPS Streamable HTTP endpoint on this server') end
          vim.ui.select(remotes, { prompt = 'Select endpoint for ' .. label(item.name, 150),
            format_item = function(remote) return remote.url end }, function(remote)
            if not remote then return end
            local id = label(item.name, 250):gsub('[^%w_-]', '-'):sub(1, 29) .. '-'
              .. vim.fn.sha256(item.name .. '\n' .. remote.url):sub(1, 10)
            local scopes = { 'Preview and search live tools (connect)', 'Install in this workspace', 'Install globally' }
            vim.ui.select(scopes, { prompt = remote.url .. ' — ' .. label(item.name, 120) .. ' (' .. id .. ')' }, function(action, index)
              if not action then return end
              vim.ui.select({ 'Browser OAuth', 'Environment token or no authentication' },
                { prompt = 'Authentication for ' .. remote.url }, function(auth)
                  if not auth then return end
                  configure_auth(remote, auth == 'Browser OAuth', function(server)
                    if index == 1 then return preview(server, oauth_cache) end
                    server.description = label(item.description, 200)
                    if server.description == '' then server.description = nil end
                    local installed, failure = M.install(config, id, server, index == 2 and workspace or nil)
                    notify(installed and ('Installed MCP server ' .. id .. '; available on the next chat turn') or failure)
                  end)
                end)
            end)
          end)
        end)
      end)
    end
    list(initial_query or '')
  end)
end

function M.manage()
  local entries, err = load()
  if not entries then return notify(err) end
  local ids = vim.tbl_keys(entries)
  table.sort(ids)
  vim.ui.select(ids, { prompt = 'Installed MCP servers (select to remove)' }, function(id)
    if not id then return end
    vim.ui.select({ 'Cancel', 'Remove' }, { prompt = 'Remove ' .. id .. '?' }, function(answer)
      if answer ~= 'Remove' then return end
      local current, failure = load()
      if not current then return notify(failure) end
      current[id] = nil
      local ok, save_err = save(current)
      notify(ok and ('Removed MCP server ' .. id) or save_err)
    end)
  end)
end

return M
