vim.opt.runtimepath:prepend(vim.fn.getcwd())
local temp = vim.fn.tempname()
vim.fn.mkdir(temp .. '/one', 'p')
vim.fn.mkdir(temp .. '/two', 'p')
vim.fn.chdir(temp .. '/one')
local history = require('codeit.chat.storage')
local workspace = history.workspace()
local requests, callbacks = {}, {}
local endpoint_error
local endpoint_catalog = {
  { tag = 'anthropic', provider_name = 'Anthropic', pricing = { prompt = '0.000003', completion = '0.000015' } },
  { tag = 'openai/fast', provider_name = 'OpenAI', pricing = { prompt = '0.000005', completion = '0.00002' } },
}
package.loaded['codeit.providers'] = {
  chat = function(config, messages, specs, callback)
    requests[#requests + 1] = { config = vim.deepcopy(config), messages = messages, specs = specs }
    callbacks[#callbacks + 1] = callback
  end,
  endpoints = function(model, callback)
    assert(model == 'vendor/beta')
    if endpoint_error then return callback(nil, endpoint_error) end
    callback(endpoint_catalog)
  end,
  models = function(provider, callback, options)
    if provider == 'copilot' then
      assert(options.api_host == 'api.business.githubcopilot.com', 'model search must use the draft host')
      return callback({ { id = 'gpt-4o', name = 'Copilot model' } })
    end
    assert(provider == 'openrouter')
    callback({ { id = 'vendor/alpha', name = 'Alpha coder' }, { id = 'vendor/beta', name = 'Beta thinker' } })
  end,
}
local plugin = require('codeit')
local settings = require('codeit.settings')
local picker = require('codeit.settings.picker')
local settings_path = vim.fn.stdpath('data') .. '/codeit/settings.json'
vim.fn.delete(settings_path)
plugin.setup({ max_context_tokens = false })
local baseline = plugin.get_settings()
local global = vim.deepcopy(baseline)
global.models.openrouter = 'global-model'
global.request_options.openrouter = { preferred_provider = 'openai', service_tier = 'priority', effort = 'high' }
global.request_options.copilot = { api_host = 'api.business.githubcopilot.com' }
assert(plugin.configure(global, 'global'))
assert(vim.fn.getfperm(settings_path) == 'rw-------')
plugin.setup({ max_context_tokens = false })
assert(plugin.get_settings().models.openrouter == 'global-model', 'global settings override setup')
assert(plugin.get_settings().request_options.copilot.api_host == 'api.business.githubcopilot.com')
local local_settings = vim.deepcopy(global)
local_settings.models.openrouter = 'workspace-model'
local_settings.request_options.openrouter = { preferred_provider = '', service_tier = '', effort = '' }
local_settings.request_options.copilot = { api_host = '' }
assert(plugin.configure(local_settings, 'workspace'))
plugin.setup({ max_context_tokens = false })
assert(plugin.get_settings().models.openrouter == 'workspace-model', 'workspace overrides global')
assert(plugin.get_settings().request_options.openrouter.effort == '', 'cleared values override global options')
assert(plugin.get_settings().request_options.copilot.api_host == '', 'workspace can restore the standard host')
vim.fn.chdir(temp .. '/two')
assert(plugin.get_settings().models.openrouter == 'global-model', 'changing workspace loads global defaults')
plugin.send('test options' .. string.rep(' details', 30))
assert(requests[#requests].config.options.effort == 'high')
assert(requests[#requests].config.model == 'global-model', 'main requests must still use the main model')
assert(not plugin.configure(local_settings), 'busy chats cannot change settings')
callbacks[#callbacks]({ role = 'assistant', content = 'Answer' })
local saved_id = history.list(history.workspace())[1].id
assert(history.load(history.workspace(), saved_id).request_options.openrouter.effort == 'high')
plugin.compact(true)
assert(requests[#requests].config.options.service_tier == 'priority', 'compaction uses options')
assert(requests[#requests].config.model == 'global-model', 'compaction inherits the main model')
callbacks[#callbacks]({ role = 'assistant', content = 'Context summary' })
plugin.history()
assert(requests[#requests].config.options.preferred_provider == 'openai', 'history uses options')
assert(requests[#requests].config.model == 'global-model', 'history inherits the main model')
callbacks[#callbacks]({ role = 'assistant', content = 'History summary' })
local session = vim.deepcopy(global)
session.models.openrouter = 'session-model'
assert(plugin.configure(session))
plugin.setup({ max_context_tokens = false })
assert(plugin.get_settings().models.openrouter == 'global-model', 'session settings are not persisted')
assert(plugin.resume(saved_id))
assert(plugin.get_settings().request_options.openrouter.effort == 'high')
vim.fn.chdir(temp .. '/one')
assert(plugin.get_settings().models.openrouter == 'workspace-model')
local invalid = vim.deepcopy(global)
invalid.request_options.openrouter.effort = 'invalid'
assert(not plugin.configure(invalid))
assert(not settings.save(global, 'bad', workspace))
for _, host in ipairs({ '', 'api.githubcopilot.com', 'api.business.githubcopilot.com' }) do
  local valid = vim.deepcopy(global)
  valid.request_options.copilot = { api_host = host }
  assert(settings.validate(valid), 'supported Copilot host should validate')
end
for _, bad in ipairs({ { api_host = 'attacker.example' }, { api_host = false },
  { api_host = 'https://api.business.githubcopilot.com' }, { api_host = 'api.business.githubcopilot.com/path' },
  { api_host = 'api.business.githubcopilot.com\n' }, { effort = 'high' }, false }) do
  invalid = vim.deepcopy(global)
  invalid.request_options.copilot = bad
  assert(not plugin.configure(invalid), 'invalid Copilot options must be rejected')
end
assert(not pcall(plugin.setup, { request_options = { copilot = { api_host = 'attacker.example' } } }))
plugin.setup({ max_context_tokens = false })

local models = { { id = 'vendor/alpha', name = 'Alpha coder' }, { id = 'vendor/beta', description = 'Reasoning model' } }
assert(#picker.search(models, '') == 2)
assert(picker.search(models, 'ALPHA coder')[1].id == 'vendor/alpha')
assert(picker.search(models, 'reasoning')[1].id == 'vendor/beta')
assert(#picker.search(models, 'missing') == 0)

-- Drive settings actions, including model browsing and scoped apply.
local steps = { 'model', 'vendor/beta', 'preferred_provider', 'anthropic', 'effort', 'high', 'service_tier', 'flex', 'workspace' }
local inputs = {}
local applied, scope
vim.ui.input = function(_, callback) callback(table.remove(inputs, 1)) end
require('codeit.settings.menu').select = function(items, _, callback)
  local wanted = table.remove(steps, 1)
  for _, item in ipairs(items) do
    if (type(item) == 'table' and (item.slug or item.id) or item) == wanted then return callback(item) end
  end
  error('missing menu choice: ' .. tostring(wanted))
end
picker.show(baseline, function(values, selected_scope) applied, scope = values, selected_scope end)
assert(scope == 'workspace' and applied.models.openrouter == 'vendor/beta')
assert(applied.request_options.openrouter.preferred_provider == 'anthropic')
assert(applied.request_options.openrouter.effort == 'high' and applied.request_options.openrouter.service_tier == 'flex')
steps, inputs = { 'model', 'vendor/alpha', 'session' }, {}
picker.show(applied, function(values) applied = values end)
assert(applied.models.openrouter == 'vendor/alpha')
steps, inputs = { 'manual', 'session' }, { ' vendor/beta ' }
picker.show(applied, function(values) applied = values end)
assert(applied.models.openrouter == 'vendor/beta')
steps, inputs = { 'manual', 'session' }, { '' }
picker.show(applied, function(values) applied = values end)
assert(applied.models.openrouter == 'vendor/beta', 'blank manual input preserves the main model')
assert(baseline.models.openrouter ~= 'vendor/beta', 'draft edits must not mutate active settings')
assert(vim.api.nvim_get_commands({}).CodeitSettings)
assert(select(1, require('codeit.commands.slash').parse('/settings')).command == 'CodeitSettings')

assert(picker.endpoint_label(endpoint_catalog[1]) == 'Anthropic [anthropic] — input $3, output $15 / 1M tokens')
assert(picker.endpoint_label({ tag = 'free', pricing = { prompt = '0', completion = 0, request = '0.01' } })
  == 'free [free] — input $0, output $0 / 1M tokens; $0.01 / request')
assert(picker.endpoint_label({ tag = 'unknown', pricing = { prompt = vim.NIL, completion = 'invalid' } })
  == 'unknown [unknown] — input unknown, output unknown / 1M tokens')
local function upstream_choice(choice)
  steps = { 'preferred_provider', choice, 'session' }
  applied = nil
  picker.show({ provider = 'openrouter', models = { openrouter = 'vendor/beta', copilot = 'test' },
    request_options = { openrouter = { preferred_provider = 'old' } } }, function(values) applied = values end)
  return applied.request_options.openrouter.preferred_provider
end
assert(upstream_choice('openai/fast') == 'openai/fast', 'use exact endpoint tags, including tier suffixes')
assert(upstream_choice('automatic') == '', 'automatic routing clears the preference')
inputs = { 'custom-provider' }
assert(upstream_choice('manual') == 'custom-provider')
endpoint_error = 'temporary failure'
assert(upstream_choice('automatic') == '', 'lookup failure still allows clearing the preference')
endpoint_error, endpoint_catalog = nil, {}
inputs = { 'unlisted-provider' }
assert(upstream_choice('manual') == 'unlisted-provider', 'empty catalogs still allow manual input')

-- Copilot host selection is part of the draft and applies to model searches.
local copilot_draft = vim.deepcopy(baseline)
copilot_draft.provider = 'copilot'
steps, inputs = { 'api_host', 'api.business.githubcopilot.com', 'model', 'gpt-4o', 'global' }, {}
picker.show(copilot_draft, function(values, selected_scope) applied, scope = values, selected_scope end)
assert(scope == 'global' and applied.request_options.copilot.api_host == 'api.business.githubcopilot.com')
assert(copilot_draft.request_options.copilot == nil, 'host selection must not mutate active settings')
steps = { 'api_host', '', 'session' }
picker.show(applied, function(values) applied = values end)
assert(applied.request_options.copilot.api_host == '', 'picker can reset the host to default')

-- Option-only updates preserve the current conversation and restore on resume.
plugin.send('Keep this chat')
callbacks[#callbacks]({ role = 'assistant', content = 'Kept' })
local current_id = history.list(workspace)[1].id
local option_only = plugin.get_settings()
option_only.request_options.openrouter.effort = 'low'
assert(plugin.configure(option_only))
assert(history.load(workspace, current_id).request_options.openrouter.effort == 'low')
assert(plugin.resume(current_id))
assert(plugin.get_settings().request_options.openrouter.effort == 'low')
plugin.send('Same conversation')
assert(requests[#requests].messages[2].content == 'Keep this chat')
callbacks[#callbacks]({ role = 'assistant', content = 'Continued' })
local preset_only = plugin.get_settings()
preset_only.model_presets.long_context = { model = 'changed-compact' }
assert(plugin.configure(preset_only))
assert(history.load(workspace, current_id).model_presets.long_context.model == 'changed-compact')
plugin.send('Preset change preserves chat')
assert(requests[#requests].config.model == 'workspace-model')
assert(requests[#requests].messages[2].content == 'Keep this chat', 'preset-only changes preserve the conversation')
callbacks[#callbacks]({ role = 'assistant', content = 'Still here' })
plugin.new()
assert(plugin.configure(local_settings))
assert(plugin.resume(current_id))
assert(plugin.get_settings().model_presets.long_context.model == 'changed-compact', 'resume restores presets')
preset_only = plugin.get_settings()
preset_only.model_presets.long_context.model = ''
assert(plugin.configure(preset_only))
plugin.compact(true)
assert(requests[#requests].config.model == 'workspace-model', 'blank preset model falls back to main model')
callbacks[#callbacks]({ role = 'assistant', content = 'Fallback summary' })
plugin.set_provider('copilot')
local copilot_settings = plugin.get_settings()
copilot_settings.request_options.copilot = { api_host = 'api.business.githubcopilot.com' }
assert(plugin.configure(copilot_settings))
plugin.send('Copilot task')
assert(requests[#requests].config.options.api_host == 'api.business.githubcopilot.com')
assert(requests[#requests].config.model == 'gpt-4o')
callbacks[#callbacks]({ role = 'assistant', content = 'Copilot answer' .. string.rep(' details', 30) })
plugin.compact(true)
assert(requests[#requests].config.provider == 'copilot' and requests[#requests].config.model == 'gpt-4o')
assert(requests[#requests].config.options.api_host == 'api.business.githubcopilot.com', 'feature requests use the host')
callbacks[#callbacks]({ role = 'assistant', content = 'Copilot summary' })
local copilot_id = history.list(workspace)[1].id
assert(history.load(workspace, copilot_id).request_options.copilot.api_host == 'api.business.githubcopilot.com')
copilot_settings.request_options.copilot.api_host = ''
plugin.new()
assert(plugin.configure(copilot_settings))
assert(plugin.resume(copilot_id))
assert(plugin.get_settings().request_options.copilot.api_host == 'api.business.githubcopilot.com',
  'resume restores the business host saved with the chat')
assert(plugin.configure(copilot_settings))
assert(history.load(workspace, copilot_id).request_options.copilot.api_host == '',
  'host-only updates are saved with the chat')
assert(history.load(workspace, copilot_id).messages[2].content == 'Copilot task',
  'host-only updates preserve the conversation')

-- Cancelling and stale UI callbacks never apply a draft.
local did_apply = false
require('codeit.settings.menu').select = function(_, _, callback) callback(nil) end
picker.show(baseline, function() did_apply = true end)
assert(not did_apply)
local held
require('codeit.settings.menu').select = function(_, _, callback) held = callback end
local live = true
picker.show(baseline, function() did_apply = true end, function() return live end)
live = false
held({ id = 'global' })
assert(not did_apply)

-- Older chats retain current preset defaults; malformed optional data is ignored.
local old_chat = history.load(workspace, current_id)
old_chat.model_presets = nil
assert(history.save(workspace, 'legacy-chat', old_chat))
assert(plugin.resume('legacy-chat'))
assert(plugin.get_settings().model_presets.long_context.model == '')
old_chat.model_presets = { long_context = { model = false } }
assert(history.save(workspace, 'bad-preset', old_chat))
assert(plugin.resume('bad-preset'))
assert(plugin.get_settings().model_presets.long_context.model == '')

-- Legacy snapshots inherit new setup defaults; explicit empty maps clear them.
local legacy = vim.deepcopy(global)
legacy.model_presets = nil
assert(settings.save(legacy, 'global', workspace))
local base = vim.deepcopy(baseline)
base.model_presets = { fast = { model = 'setup-fast' } }
assert(settings.resolve(base, temp .. '/two').model_presets.fast.model == 'setup-fast')
legacy.model_presets = {}
assert(settings.save(legacy, 'global', workspace))
assert(vim.deep_equal(settings.resolve(base, temp .. '/two').model_presets, {}))

-- Invalid persisted JSON must not be overwritten or crash startup.
vim.fn.writefile({ 'not json' }, settings_path)
assert(not settings.save(global, 'global', workspace))
assert(settings.resolve(baseline, workspace).models.openrouter == baseline.models.openrouter)
vim.fn.delete(settings_path)
vim.fn.delete(temp, 'rf')
print('codeit settings tests passed')
