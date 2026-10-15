vim.opt.runtimepath:prepend(vim.fn.getcwd())
local temp = vim.fn.tempname()
vim.fn.mkdir(temp, 'p')
vim.fn.chdir(temp)
local settings = require('codeit.settings')
local defaults = require('codeit.settings.defaults')
local values = { provider = 'openai', models = vim.deepcopy(defaults.models),
  request_options = { openai = { base_url = 'http://localhost:1234/v1', api_key_env = '' } },
  model_presets = { fast = { provider = 'openai', model = 'local-fast',
    options = { base_url = 'http://localhost:5678/v1', api_key_env = 'LOCAL_API_KEY' } } },
  feature_settings = { subagent = { provider = 'openai', options = { api_key_env = '' } } } }
assert(settings.validate(values))
local resolved = settings.feature_config(values, 'subagent')
assert(resolved.model == 'local-fast' and resolved.options.base_url == 'http://localhost:5678/v1')
assert(resolved.options.api_key_env == '', 'features can disable inherited authentication')
for _, options in ipairs({ { api_key_env = false }, { api_key_env = 'bad-name' },
  { base_url = false }, { base_url = 'ftp://host' }, { api_key = 'secret' }, { effort = 'high' } }) do
  local invalid = vim.deepcopy(values)
  invalid.request_options.openai = options
  assert(not settings.validate(invalid))
end
local legacy = { provider = 'copilot', models = { openrouter = 'a', copilot = 'b' }, request_options = {} }
assert(settings.validate(legacy), 'older snapshots must remain valid without an OpenAI model')
legacy.provider = 'openai'
assert(not settings.validate(legacy), 'the selected backend needs a model')
local config
package.loaded['codeit.providers'] = {
  chat = function(selected, _, _, callback)
    config = selected
    callback({ role = 'assistant', content = 'ok' }, nil,
      { prompt_tokens = 10, completion_tokens = 5, total_tokens = 15, cached_tokens = 4 })
  end,
  models = function(provider, callback, options)
    assert(provider == 'openai' and options.base_url == 'http://localhost:9876/v1')
    callback({ { id = 'local-model' } })
  end,
}
local plugin = require('codeit')
vim.fn.delete(vim.fn.stdpath('data') .. '/codeit/settings.json')
plugin.setup({ provider = 'openai', max_context_tokens = false, context_review = false,
  request_options = values.request_options })
assert(plugin.get_settings().provider == 'openai')
assert(vim.tbl_contains(vim.fn.getcompletion('CodeitProvider ', 'cmdline'), 'openai'))
local slash = require('codeit.commands.slash').complete_items('/provider')
assert(#slash > 0)
local picker = require('codeit.settings.picker')
local actions = { 'base_url', 'api_key_env', 'model', 'local-model', 'session' }
local menu = require('codeit.settings.menu')
local original_select = menu.select
menu.select = function(items, _, callback)
  local action = table.remove(actions, 1)
  assert(action, 'unexpected menu')
  for _, item in ipairs(items) do
    if item.id == action then return callback(item) end
  end
  error('missing menu item: ' .. action)
end
local input = require('codeit.ui.input')
local original_input = input.show
input.show = function(opts, callback)
  callback(opts.prompt:find('base_url', 1, true) and 'http://localhost:9876/v1' or '')
end
picker.show(plugin.get_settings(), function(draft, scope)
  assert(scope == 'session' and draft.models.openai == 'local-model')
  assert(plugin.configure(draft))
end)
assert(#actions == 0)
menu.select, input.show = original_select, original_input
plugin.send('hello')
assert(config.provider == 'openai' and config.model == 'local-model')
assert(config.options.base_url == 'http://localhost:9876/v1' and config.options.api_key_env == '')
local history = require('codeit.chat.storage')
local chats = history.list(history.workspace())
assert(#chats == 1 and chats[1].provider == 'openai')
assert(chats[1].tokens_in == 10 and chats[1].tokens_out == 5, 'compatible-provider usage must be recorded')
assert(plugin.resume(chats[1].id), 'compatible-provider chats must resume')
assert(settings.save(plugin.get_settings(), 'workspace', history.workspace()))
plugin.setup({ max_context_tokens = false })
assert(plugin.get_settings().provider == 'openai', 'saved settings must restore the backend')
plugin.set_provider('copilot')
plugin.set_provider('openai')
assert(plugin.get_settings().provider == 'openai', 'provider switching must accept openai')
vim.fn.delete(vim.fn.stdpath('data') .. '/codeit/settings.json')
vim.fn.delete(temp, 'rf')
print('codeit OpenAI-compatible settings tests passed')
