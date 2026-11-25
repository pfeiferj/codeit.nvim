local M = {}
local settings = require('codeit.settings.mcp')
local registry = require('codeit.tools.mcp_registry')

local function sorted(map)
  local names = vim.tbl_keys(map or {})
  table.sort(names)
  return names
end

local function status(value)
  if value == nil then return 'Inherit' end
  return value and 'Enabled' or 'Disabled'
end

function M.show(context, live, back)
  local workspace = context.workspace
  local base_registries = context.registries or {}
  local menu, servers, registries, server_menu, registry_menu
  local function select(title, items, action)
    if not live() then return end
    require('codeit.settings.menu').select(items, { prompt = title, format_item = function(item) return item.label end }, function(item)
      if live() then action(item or {}) end
    end)
  end
  local function input(prompt, default, done, cancel)
    require('codeit.ui.input').show({ prompt = prompt, default = default or '' }, function(value)
      if not live() then return end
      if value == nil then return cancel() end
      done(vim.trim(value))
    end)
  end
  local function warn(err) vim.notify('codeit: ' .. tostring(err), vim.log.levels.WARN) end
  local function finish(ok, err, next_menu)
    if not ok then warn(err) end
    next_menu()
  end
  local function set(section, id, value, next_menu)
    local ok, err = settings.set(section, id, value, workspace)
    finish(ok, err, next_menu)
  end
  local function confirm(label, done, cancel)
    select(label, { { label = 'Cancel' }, { id = 'confirm', label = label } }, function(item)
      if item.id then done() else cancel() end
    end)
  end
  local function override(title, section, id, previous, next_menu)
    select(title, { { id = 'inherit', label = 'Inherit (' .. status(previous) .. ')' },
      { id = 'on', label = 'Enabled' }, { id = 'off', label = 'Disabled' } }, function(item)
      if not item.id then return next_menu() end
      local value
      if item.id ~= 'inherit' then value = item.id == 'on' end
      set(section, id, value, next_menu)
    end)
  end
  local function field(items, id, label, value, kind)
    items[#items + 1] = { id = id, label = label .. ': ' .. (value and tostring(value) or '(not set)'), title = label, kind = kind }
  end
  local function name(prompt, taken, done, cancel)
    input(prompt, nil, function(id)
      if #id > 40 or not id:match('^[%w_-]+$') or taken[id] then
        warn('Choose an unused ID of 1–40 letters, digits, hyphens, or underscores')
        return cancel()
      end
      done(id)
    end, cancel)
  end

  local function edit_server(id, initial, remote, installed, return_to)
    local draft = vim.deepcopy(initial or {})
    local editor
    editor = function()
      local items = {}
      field(items, 'description', 'Short description', draft.description)
      field(items, 'timeout_ms', 'Request timeout (ms)', draft.timeout_ms, 'number')
      if remote then
        field(items, 'url', 'Remote endpoint URL (no credentials)', draft.url)
        field(items, 'auth', 'Authentication', draft.oauth and 'Browser OAuth' or (draft.bearer_token_env and 'Bearer token' or 'None'))
        field(items, 'header_env', 'Header-to-environment-variable map (JSON)', draft.header_env and vim.json.encode(draft.header_env), 'object')
        if draft.bearer_token_env then field(items, 'bearer_token_env', 'Bearer token environment variable', draft.bearer_token_env) end
        if draft.oauth then
          field(items, 'client_id', 'OAuth client ID', draft.oauth.client_id, 'oauth')
          field(items, 'issuer', 'OAuth issuer', draft.oauth.issuer, 'oauth')
          field(items, 'resource', 'OAuth resource', draft.oauth.resource, 'oauth')
          field(items, 'token_url', 'OAuth token URL', draft.oauth.token_url, 'oauth')
          field(items, 'redirect_url', 'OAuth loopback redirect URL', draft.oauth.redirect_url, 'oauth')
          field(items, 'client_secret_env', 'OAuth client secret environment variable', draft.oauth.client_secret_env, 'oauth')
          field(items, 'redirect_port', 'OAuth redirect port', draft.oauth.redirect_port, 'oauth_number')
          field(items, 'scopes', 'OAuth scopes (space separated)', draft.oauth.scopes and table.concat(draft.oauth.scopes, ' '), 'scopes')
        end
      else
        field(items, 'command', 'Stdio executable', draft.command)
        field(items, 'args', 'Stdio arguments (JSON array; no credentials)', draft.args and vim.json.encode(draft.args), 'array')
      end
      items[#items + 1] = { id = 'save', label = 'Save server', section = 'Apply changes' }
      items[#items + 1] = { label = 'Discard and go back' }
      select('MCP server: ' .. id, items, function(item)
        local key = item.id
        if not key then return return_to() end
        if key == 'save' then
          local server, err = settings.server(id, draft)
          if not server then warn(err); return editor() end
          if installed then
            local ok, failure = registry.update_install(id, server, workspace)
            return finish(ok, failure, ok and return_to or editor)
          end
          local ok, failure = settings.set('servers', id, server, workspace)
          return finish(ok, failure, ok and return_to or editor)
        end
        if key == 'auth' then
          return select('MCP authentication', { { id = 'none', label = 'None / custom headers only' },
            { id = 'token', label = 'Bearer token from environment' }, { id = 'oauth', label = 'Browser OAuth' } }, function(auth)
            if auth.id == 'token' then
              return input('Bearer token environment variable: ', draft.bearer_token_env, function(value)
                if require('codeit.tools.mcp_http').env_name(value) then draft.bearer_token_env, draft.oauth = value, nil
                else warn('Enter a valid environment variable name') end
                editor()
              end, editor)
            end
            if auth.id then
              draft.bearer_token_env = nil
              draft.oauth = auth.id == 'oauth' and (draft.oauth or {}) or nil
            end
            editor()
          end)
        end
        local holder = ((item.kind or ''):match('^oauth') or item.kind == 'scopes') and draft.oauth or draft
        local value = holder[key]
        if type(value) == 'table' then value = item.kind == 'scopes' and table.concat(value, ' ') or vim.json.encode(value) end
        input(item.title .. ' (blank to clear): ', value and tostring(value), function(text)
          local parsed = text ~= '' and text or nil
          if parsed and (item.kind == 'number' or item.kind == 'oauth_number') then
            parsed = tonumber(text)
            if not parsed then warn('Enter a number'); return editor() end
          elseif parsed and (item.kind == 'object' or item.kind == 'array') then
            local ok, decoded = pcall(vim.json.decode, text)
            if not ok or type(decoded) ~= 'table' or vim.islist(decoded) ~= (item.kind == 'array') then
              warn('Enter a JSON ' .. item.kind); return editor()
            end
            parsed = decoded
          elseif parsed and item.kind == 'scopes' then
            parsed = vim.split(text, '%s+', { trimempty = true })
          end
          holder[key] = parsed
          editor()
        end, editor)
      end)
    end
    editor()
  end

  server_menu = function(id)
    local saved = settings.read()
    local config, sources = settings.resolve(context.base, workspace, saved)
    local server, source = config.servers[id], sources[id]
    if not server then return servers() end
    local enabled = (saved.enabled or {})[id]
    local overrides = (saved.workspaces or {})[workspace] or {}
    local base_workspace = (context.base.workspaces[workspace] or {})[id]
    local default = source == 'setup' and context.base.servers[id] or (saved.servers or {})[id]
    local default_enabled = not default or default.enabled ~= false
    local items = {
      { id = 'workspace', label = 'This workspace: ' .. status(overrides[id]) .. ' (effective: '
        .. status((config.workspaces[workspace][id] == nil and server.enabled) or config.workspaces[workspace][id] == true) .. ')' },
      { id = 'global', label = 'Global default: ' .. status(enabled) .. ' (effective: ' .. status(server.enabled) .. ')' },
    }
    if source ~= 'setup' then items[#items + 1] = { id = 'edit', label = 'Edit server connection' } end
    if source == 'settings' then
      items[#items + 1] = { id = 'remove', label = 'Remove global server' }
    elseif source == 'registry' then
      items[#items + 1] = { id = 'uninstall', label = 'Uninstall MCP server' }
    end
    items[#items + 1] = { label = source == 'setup' and 'Back (connection defined in setup())' or 'Back to servers' }
    local reopen = function() server_menu(id) end
    select('MCP server: ' .. id .. ' (' .. source .. ')', items, function(item)
      if item.id == 'workspace' then
        local inherited = base_workspace
        if inherited == nil then inherited = server.enabled end
        override('Workspace MCP server: ' .. id, 'workspaces', id, inherited, reopen)
      elseif item.id == 'global' then override('Global MCP server default: ' .. id, 'enabled', id, default_enabled, reopen)
      elseif item.id == 'edit' then
        edit_server(id, source == 'settings' and (saved.servers or {})[id] or server, server.url ~= nil, source == 'registry', reopen)
      elseif item.id == 'remove' then
        confirm('Remove global MCP server ' .. id, function() set('servers', id, nil, servers) end, reopen)
      elseif item.id == 'uninstall' then
        confirm('Uninstall MCP server ' .. id, function()
          local ok, err = registry.uninstall(id, workspace)
          finish(ok, err, ok and servers or reopen)
        end, reopen)
      else servers() end
    end)
  end
  servers = function()
    local config, sources = settings.resolve(context.base, workspace)
    local items = { { id = '+', label = 'Add global MCP server' } }
    for _, id in ipairs(sorted(config.servers)) do
      local enabled = config.workspaces[workspace][id]
      if enabled == nil then enabled = config.servers[id].enabled end
      items[#items + 1] = { id = id, label = id .. ': ' .. status(enabled) .. ' here (' .. sources[id] .. ')' }
    end
    items[#items + 1] = { label = 'Back to MCP settings' }
    select('MCP servers — current workspace', items, function(item)
      if item.id == '+' then
        name('New global MCP server ID: ', config.servers, function(id)
          select('MCP transport', { { id = 'http', label = 'Remote (Streamable HTTP)' }, { id = 'stdio', label = 'Local (stdio)' } }, function(transport)
            if transport.id then edit_server(id, {}, transport.id == 'http', false, servers) else servers() end
          end)
        end, servers)
      elseif item.id then server_menu(item.id) else menu() end
    end)
  end

  registry_menu = function(id)
    local saved = settings.read()
    local effective = settings.registries(base_registries, saved)[id]
    local previous = (saved.registries or {})[id]
    local reopen = function() registry_menu(id) end
    local items = { { id = 'edit', label = 'Edit registry URL and authentication' } }
    if effective then
      items[#items + 1] = { id = 'oauth_metadata', label = 'OAuth metadata paths' }
      items[#items + 1] = { id = 'disable', label = 'Disable registry globally' }
    end
    if previous ~= nil then
      if base_registries[id] then
        items[#items + 1] = { id = 'reset', label = 'Remove saved override / restore default' }
      else
        items[#items + 1] = { id = 'delete', label = 'Delete custom registry' }
      end
    end
    items[#items + 1] = { label = 'Back to registries' }
    select('MCP registry: ' .. id, items, function(item)
      if item.id == 'edit' then
        input('MCP Registry API URL (no credentials): ', (effective or {}).url, function(url)
          input('Registry bearer token environment variable (blank for none): ', (effective or {}).bearer_token_env, function(token)
            local value, err = settings.registry(id, { url = url, bearer_token_env = token ~= '' and token or nil,
              oauth_metadata = (effective or {}).oauth_metadata })
            if not value then warn(err); return reopen() end
            set('registries', id, value, reopen)
          end, reopen)
        end, reopen)
      elseif item.id == 'oauth_metadata' then
        local mappings = vim.deepcopy(effective.oauth_metadata or {})
        local function edit_paths()
          local fields = {}
          for _, key in ipairs(registry.oauth_fields) do field(fields, key, key, mappings[key]) end
          fields[#fields + 1] = { label = 'Back to registry' }
          select('OAuth paths in server _meta: ' .. id, fields, function(choice)
            if not choice.id then return reopen() end
            input(choice.id .. ' path relative to _meta (blank to clear): ', mappings[choice.id], function(path)
              local updated = vim.deepcopy(mappings)
              updated[choice.id] = path ~= '' and path or nil
              local value, err = settings.registry(id, vim.tbl_extend('force', effective, { oauth_metadata = updated }))
              if not value then warn(err); return edit_paths() end
              local ok, failure = settings.set('registries', id, value, workspace)
              if ok then mappings = updated else warn(failure) end
              edit_paths()
            end, edit_paths)
          end)
        end
        edit_paths()
      elseif item.id == 'disable' then set('registries', id, false, registries)
      elseif item.id == 'reset' then set('registries', id, nil, registries)
      elseif item.id == 'delete' then
        confirm('Delete custom MCP registry ' .. id, function()
          set('registries', id, nil, registries)
        end, reopen)
      else registries() end
    end)
  end
  registries = function()
    local saved = settings.read()
    local effective = settings.registries(base_registries, saved)
    local ids = vim.tbl_extend('force', {}, base_registries, saved.registries or {})
    local items = { { id = '+', label = 'Add global MCP registry' } }
    for _, id in ipairs(sorted(ids)) do
      items[#items + 1] = { id = id, label = id .. ': ' .. (effective[id] and effective[id].url or 'Disabled') }
    end
    items[#items + 1] = { label = 'Back to MCP settings' }
    select('MCP registries — global', items, function(item)
      if item.id == '+' then name('New global MCP registry ID: ', ids, registry_menu, registries)
      elseif item.id then registry_menu(item.id) else menu() end
    end)
  end
  menu = function()
    select('MCP settings', { { id = 'servers', label = 'Servers and workspace overrides' },
      { id = 'registries', label = 'Registries' }, { label = 'Back to Codeit settings' } }, function(item)
      if item.id == 'servers' then servers()
      elseif item.id == 'registries' then registries()
      else back() end
    end)
  end
  menu()
end

return M
