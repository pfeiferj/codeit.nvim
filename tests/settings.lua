vim.opt.runtimepath:prepend(vim.fn.getcwd())
local temp = vim.fn.tempname()
vim.fn.mkdir(temp .. '/one', 'p')
vim.fn.mkdir(temp .. '/two', 'p')
vim.fn.chdir(temp .. '/one')
local history = require('codeit.history')
local workspace = history.workspace()
local requests, callbacks = {}, {}
package.loaded['codeit.providers'] = {
  chat = function(config, messages, specs, callback)
    requests[#requests + 1] = { config = vim.deepcopy(config), messages = messages, specs = specs }
    callbacks[#callbacks + 1] = callback
  end,
  models = function(provider, callback)
    assert(provider == 'openrouter')
    callback({ { id = 'vendor/alpha', name = 'Alpha coder' }, { id = 'vendor/beta', name = 'Beta thinker' } })
  end,
}
local plugin = require('codeit')
local settings = require('codeit.settings')
local picker = require('codeit.settings_picker')
local settings_path = vim.fn.stdpath('data') .. '/codeit/settings.json'
vim.fn.delete(settings_path)
plugin.setup({ max_context_tokens = false })
local baseline = plugin.get_settings()
local global = vim.deepcopy(baseline)
global.models.openrouter = 'global-model'
global.request_options.openrouter = { preferred_provider = 'openai', service_tier = 'priority', effort = 'high' }
assert(plugin.configure(global, 'global'))
assert(vim.fn.getfperm(settings_path) == 'rw-------')
plugin.setup({ max_context_tokens = false })
assert(plugin.get_settings().models.openrouter == 'global-model', 'global settings override setup')
local local_settings = vim.deepcopy(global)
local_settings.models.openrouter = 'workspace-model'
local_settings.request_options.openrouter = { preferred_provider = '', service_tier = '', effort = '' }
assert(plugin.configure(local_settings, 'workspace'))
plugin.setup({ max_context_tokens = false })
assert(plugin.get_settings().models.openrouter == 'workspace-model', 'workspace overrides global')
assert(plugin.get_settings().request_options.openrouter.effort == '', 'cleared values override global options')
vim.fn.chdir(temp .. '/two')
assert(plugin.get_settings().models.openrouter == 'global-model', 'changing workspace loads global defaults')
plugin.send('test options')
assert(requests[#requests].config.options.effort == 'high')
assert(not plugin.configure(local_settings), 'busy chats cannot change settings')
callbacks[#callbacks]({ role = 'assistant', content = 'Answer' })
local saved_id = history.list(history.workspace())[1].id
assert(history.load(history.workspace(), saved_id).request_options.openrouter.effort == 'high')
plugin.compact()
assert(requests[#requests].config.options.service_tier == 'priority', 'compaction uses options')
callbacks[#callbacks]({ role = 'assistant', content = 'Context summary' })
plugin.history()
assert(requests[#requests].config.options.preferred_provider == 'openai', 'history uses options')
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

local models = { { id = 'vendor/alpha', name = 'Alpha coder' }, { id = 'vendor/beta', description = 'Reasoning model' } }
assert(#picker.search(models, '') == 2)
assert(picker.search(models, 'ALPHA coder')[1].id == 'vendor/alpha')
assert(picker.search(models, 'reasoning')[1].id == 'vendor/beta')
assert(#picker.search(models, 'missing') == 0)

-- Drive the actual settings menu, including search and scoped apply.
local steps = { 'model', 'vendor/beta', 'preferred_provider', 'effort', 'high', 'service_tier', 'flex', 'workspace' }
local inputs = { 'beta', 'anthropic' }
local applied, scope
vim.ui.input = function(_, callback) callback(table.remove(inputs, 1)) end
vim.ui.select = function(items, _, callback)
  local wanted = table.remove(steps, 1)
  for _, item in ipairs(items) do
    if (type(item) == 'table' and item.id or item) == wanted then return callback(item) end
  end
  error('missing menu choice: ' .. tostring(wanted))
end
picker.show(baseline, function(values, selected_scope) applied, scope = values, selected_scope end)
assert(scope == 'workspace' and applied.models.openrouter == 'vendor/beta')
assert(applied.request_options.openrouter.preferred_provider == 'anthropic')
assert(applied.request_options.openrouter.effort == 'high' and applied.request_options.openrouter.service_tier == 'flex')
assert(baseline.models.openrouter ~= 'vendor/beta', 'draft edits must not mutate active settings')
assert(vim.api.nvim_get_commands({}).CodeitSettings)
assert(select(1, require('codeit.slash_commands').parse('/settings')).command == 'CodeitSettings')

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

-- Cancelling and stale UI callbacks never apply a draft.
local did_apply = false
vim.ui.select = function(_, _, callback) callback(nil) end
picker.show(baseline, function() did_apply = true end)
assert(not did_apply)
local held
vim.ui.select = function(_, _, callback) held = callback end
local live = true
picker.show(baseline, function() did_apply = true end, function() return live end)
live = false
held({ id = 'global' })
assert(not did_apply)

-- Invalid persisted JSON must not be overwritten or crash startup.
vim.fn.writefile({ 'not json' }, settings_path)
assert(not settings.save(global, 'global', workspace))
assert(settings.resolve(baseline, workspace).models.openrouter == baseline.models.openrouter)
vim.fn.delete(settings_path)
vim.fn.delete(temp, 'rf')
print('codeit settings tests passed')
