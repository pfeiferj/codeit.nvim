vim.opt.runtimepath:prepend(vim.fn.getcwd())
local plugin = require('codeit')
local stored = require('codeit.settings.mcp')
local registry = require('codeit.tools.mcp_registry')
local mcp = require('codeit.tools.mcp')
local workspace = require('codeit.chat.storage').workspace()
local setup = { servers = { lua_server = { command = 'example', env = { TOKEN = 'setup-only-secret' }, enabled = false } },
  registries = { private = 'https://registry.example.test' } }
local menu, input
require('codeit.settings.menu').select = function(items, opts, cb) menu = { items = items, prompt = opts.prompt, cb = cb } end
require('codeit.ui.input').show = function(opts, cb) input = { opts = opts, cb = cb } end
local function choose(id)
  local current = assert(menu)
  for index, item in ipairs(current.items) do
    if item.id == id then menu = nil; return current.cb(item, index) end
  end
  error('No item ' .. tostring(id) .. ' in ' .. current.prompt)
end
local function type_in(text)
  local current = assert(input)
  input = nil
  current.cb(text)
end
plugin.setup({ mcp = setup, max_context_tokens = false, context_review = false })
vim.cmd('CodeitSettings')
choose('mcp')
choose('servers')
choose('+')
type_in('notes')
choose('http')
choose('url')
type_in('https://example.test/mcp')
choose('auth')
choose('oauth')
choose('client_id')
type_in('public-client')
choose('redirect_port')
type_in('33418')
choose('header_env')
type_in('{"X-Key":"NOTES_API_KEY"}')
choose('save')
choose('notes')
choose('workspace')
choose('off')
local base = mcp.configure(setup)
local resolved = stored.resolve(base, workspace)
assert(resolved.servers.notes.oauth.client_id == 'public-client' and resolved.servers.notes.oauth.redirect_port == 33418)
assert(resolved.servers.notes.header_env['X-Key'] == 'NOTES_API_KEY')
assert(resolved.workspaces[workspace].notes == false and resolved.servers.notes.enabled)
local elsewhere = stored.resolve(base, workspace .. '/another')
assert(elsewhere.workspaces[workspace .. '/another'].notes == nil and elsewhere.servers.notes.enabled)
choose('workspace')
choose('inherit')
assert(stored.resolve(base, workspace).workspaces[workspace].notes == nil)
choose(nil)
choose('lua_server')
choose('global')
choose('on')
resolved = stored.resolve(base, workspace)
assert(resolved.servers.lua_server.enabled and not base.servers.lua_server.enabled)
assert(resolved.servers.lua_server.env.TOKEN == 'setup-only-secret')
choose(nil)
choose(nil)
choose('registries')
choose('github')
choose('disable')
choose('+')
type_in('custom')
choose('edit')
type_in('https://example.test/registry')
type_in('REGISTRY_TOKEN')
local picked
registry.browse = function(registries) picked = registries end
vim.cmd('CodeitMcpRegistry')
assert(picked.github == nil and picked.private.url == 'https://registry.example.test')
assert(picked.custom.bearer_token_env == 'REGISTRY_TOKEN')
choose(nil)
choose('github')
choose('reset')
vim.cmd('CodeitMcpRegistry')
assert(picked.github.url == 'https://api.mcp.github.com')

assert(registry.install(base, 'scoped', { url = 'https://example.test/old' }, workspace))
assert(registry.update_install('scoped', { url = 'https://example.test/new' }, workspace))
assert(stored.resolve(base, workspace).servers.scoped.url == 'https://example.test/new')
assert(stored.resolve(base, workspace .. '/another').servers.scoped == nil)

local values = plugin.get_settings()
assert(plugin.configure(values, 'global'))
local persisted = table.concat(vim.fn.readfile(vim.fn.stdpath('data') .. '/codeit/settings.json'))
assert(not persisted:find('setup-only-secret', 1, true))
assert(stored.resolve(base, workspace).servers.notes)

local advertised
require('codeit.providers').chat = function(_, _, specs, done)
  for _, tool in ipairs(specs) do
    local fn = tool['function']
    if fn.name == mcp.discovery_name then advertised = fn.parameters.properties.server.enum end
  end
  done({ role = 'assistant', content = 'Done' })
end
plugin.send('Inspect available tools')
assert(vim.deep_equal(advertised, { 'lua_server', 'notes', 'scoped' }))
