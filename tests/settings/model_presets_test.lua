vim.opt.runtimepath:prepend(vim.fn.getcwd())
local temp = vim.fn.tempname()
vim.fn.mkdir(temp .. '/one', 'p')
vim.fn.mkdir(temp .. '/two', 'p')
vim.fn.chdir(temp .. '/one')
local settings = require('codeit.settings')
local history = require('codeit.chat.storage')
local workspace = history.workspace()
local path = vim.fn.stdpath('data') .. '/codeit/settings.json'
vim.fn.delete(path)
local requests, callbacks, searches, endpoints = {}, {}, {}, {}
package.loaded['codeit.providers'] = {
  chat = function(config, messages, specs, callback)
    requests[#requests + 1] = { config = vim.deepcopy(config), messages = messages, specs = specs }
    callbacks[#callbacks + 1] = callback
  end,
  models = function(provider, callback, options)
    searches[#searches + 1] = { provider = provider, options = vim.deepcopy(options) }
    callback({ { id = 'picked-model' } })
  end,
  endpoints = function(model, callback)
    endpoints[#endpoints + 1] = model
    callback({ { tag = 'upstream' } })
  end,
}
local plugin = require('codeit')
local options = {
  openrouter = { effort = 'medium', service_tier = 'flex', preferred_provider = 'main-upstream' },
  copilot = { api_host = 'api.business.githubcopilot.com' },
}
plugin.setup({ max_context_tokens = false, request_options = options })
local baseline = plugin.get_settings()
local defaults = {
  tool_assessment = 'fast', tool_review = 'reasoning', context_review = 'long_context',
  history_summary = 'fast', compaction = 'long_context',
}
assert(vim.deep_equal(settings.presets, { 'fast', 'long_context', 'reasoning' }))
assert(vim.deep_equal(baseline.model_presets, {}))
assert(baseline.secondary_models == nil)
-- Obsolete saved fields are ignored, including malformed values, without losing main settings.
local obsolete = vim.deepcopy(baseline)
obsolete.models.openrouter = 'saved-main'
for _, old in ipairs({ { openrouter = 'obsolete-model' }, false }) do
  obsolete.secondary_models = old
  assert(settings.validate(obsolete))
  assert(settings.save(obsolete, 'global', workspace))
  local resolved = settings.resolve(baseline, workspace)
  assert(resolved.models.openrouter == 'saved-main' and resolved.secondary_models == nil)
  for _, name in ipairs(settings.features) do
    assert(settings.feature_config(resolved, name).model == 'saved-main')
  end
end
vim.fn.delete(path)
for name, preset in pairs(defaults) do
  assert(settings.feature_preset(baseline, name) == preset)
  local selected = settings.feature_config(baseline, name, 'resumed-main')
  assert(selected.provider == baseline.provider and selected.model == 'resumed-main')
  assert(vim.deep_equal(selected.options, options.openrouter))
end
for _, name in ipairs(settings.presets) do
  assert(settings.preset_config(baseline, name, 'resumed-main').model == 'resumed-main')
end
-- Inheritance stays live when the main model, backend, or request options change.
local live_defaults = vim.deepcopy(baseline)
live_defaults.models.openrouter = 'updated-main'
live_defaults.request_options.openrouter.effort = 'xhigh'
for _, name in ipairs(settings.presets) do
  local selected = settings.preset_config(live_defaults, name)
  assert(selected.model == 'updated-main' and selected.options.effort == 'xhigh')
end
live_defaults.provider = 'copilot'
live_defaults.models.copilot = 'updated-copilot'
live_defaults.request_options.copilot.api_host = ''
for name in pairs(defaults) do
  local selected = settings.feature_config(live_defaults, name)
  assert(selected.provider == 'copilot' and selected.model == 'updated-copilot')
  assert(selected.options.api_host == '' and selected.options.effort == nil)
end
local presets = {
  fast = { model = 'fast-model', options = { effort = 'low' } },
  long_context = { provider = 'copilot', model = 'long-model' },
  reasoning = { model = 'reasoning-model', options = { effort = 'high', service_tier = 'priority' } },
}
local base = vim.deepcopy(baseline)
base.model_presets = vim.deepcopy(presets)
assert(settings.validate(base))
for name, preset in pairs(defaults) do
  local selected = settings.feature_config(base, name)
  assert(selected.model == presets[preset].model)
  assert(selected.provider == (presets[preset].provider or baseline.provider))
end
assert(settings.feature_config(base, 'context_review').options.api_host == options.copilot.api_host)
assert(settings.feature_config(base, 'history_summary').options.service_tier == 'flex')
assert(settings.feature_config(base, 'tool_review').options.preferred_provider == 'main-upstream')
-- Both presets and features fall back directly to the main chat.
local inherited = vim.deepcopy(base)
inherited.model_presets.fast = { provider = '', model = '', options = { effort = '' } }
assert(settings.preset_config(inherited, 'fast', 'resumed-main').model == 'resumed-main')
assert(settings.feature_config(inherited, 'history_summary', 'resumed-main').model == 'resumed-main')
assert(settings.feature_config(inherited, 'history_summary').options.effort == '')
inherited.model_presets.long_context.model = ''
assert(settings.preset_config(inherited, 'long_context', 'resumed-main').model == baseline.models.copilot)
-- Individual feature fields override the preset; omitted option keys still inherit.
inherited = vim.deepcopy(base)
inherited.feature_settings.tool_review = { preset = 'fast', model = 'feature-model',
  options = { service_tier = '', preferred_provider = '' } }
local selected = settings.feature_config(inherited, 'tool_review')
assert(selected.model == 'feature-model' and selected.options.effort == 'low')
assert(selected.options.service_tier == '' and selected.options.preferred_provider == '')
inherited.feature_settings.tool_review = { preset = '' }
selected = settings.feature_config(inherited, 'tool_review', 'resumed-main')
assert(selected.model == 'resumed-main' and selected.options.effort == 'medium')
inherited.feature_settings.compaction = { provider = 'openrouter', model = 'feature-openrouter',
  options = { effort = 'xhigh', api_host = '' } }
selected = settings.feature_config(inherited, 'compaction')
assert(selected.provider == 'openrouter' and selected.model == 'feature-openrouter')
assert(selected.options.effort == 'xhigh' and selected.options.api_host == nil)
selected.options.effort = 'none'
assert(base.model_presets.reasoning.options.effort == 'high')
assert(inherited.feature_settings.compaction.options.effort == 'xhigh')
assert(vim.deep_equal(base.request_options, options), 'resolution must not mutate main options')
assert(vim.deep_equal(base.model_presets, presets), 'resolution must not mutate presets')
for _, bad in ipairs({ false, 'fast', { unknown = {} }, { fast = false },
  { fast = { provider = false } }, { fast = { provider = 'unknown' } },
  { fast = { model = false } }, { fast = { model = '   ' } }, { fast = { model = 'bad\nmodel' } },
  { fast = { preset = 'reasoning' } }, { fast = { unknown = true } }, { fast = { options = false } },
  { fast = { options = { unknown = '' } } }, { fast = { options = { effort = 'invalid' } } },
  { fast = { options = { service_tier = 'invalid' } } },
  { fast = { options = { preferred_provider = 'bad\nslug' } } },
  { fast = { options = { api_host = 'attacker.example' } } },
}) do
  local invalid = vim.deepcopy(base)
  invalid.model_presets = bad
  assert(not settings.validate(invalid), 'invalid presets must be rejected')
  assert(not plugin.configure(invalid))
  assert(not pcall(plugin.setup, invalid))
end
for _, bad in ipairs({ false, 'unknown', 'long context', {} }) do
  local invalid = vim.deepcopy(base)
  invalid.feature_settings = { compaction = { preset = bad } }
  assert(not settings.validate(invalid), 'invalid preset selection must be rejected')
  assert(not plugin.configure(invalid))
  assert(not pcall(plugin.setup, invalid))
end
-- Complete snapshots persist presets; legacy snapshots inherit, empty maps clear.
assert(settings.save(base, 'global', workspace))
assert(vim.deep_equal(settings.resolve(baseline, workspace).model_presets, presets))
local scoped = vim.deepcopy(base)
scoped.model_presets.fast.model = 'workspace-fast'
assert(settings.save(scoped, 'workspace', workspace))
assert(settings.resolve(baseline, workspace).model_presets.fast.model == 'workspace-fast')
scoped.model_presets = nil
assert(settings.save(scoped, 'workspace', workspace))
assert(vim.deep_equal(settings.resolve(baseline, workspace).model_presets, presets))
scoped.model_presets = {}
assert(settings.save(scoped, 'workspace', workspace))
assert(vim.deep_equal(settings.resolve(base, workspace).model_presets, {}))
vim.fn.delete(path)
-- Actual feature requests use their default presets, not the main model.
plugin.setup({ max_context_tokens = false, context_review_min_tokens = 0, request_options = options, model_presets = presets })
local function reply(content)
  callbacks[#callbacks]({ role = 'assistant', content = content }, nil,
    { cost = 0, prompt_tokens = 10, completion_tokens = 5 })
end
plugin.send('Check a tool')
assert(requests[#requests].config.model == baseline.models.openrouter)
assert(requests[#requests].config.options.effort == 'medium')
local prompt = require('codeit.tools.approval.prompt')
local choose, ask
prompt.show = function(_, _, callback) choose = callback end
prompt.ask_reviewer = function(_, _, callback) ask = callback end
vim.ui.input = function(_, callback) callback('Not needed') end
callbacks[#callbacks]({ role = 'assistant', tool_calls = {
  { id = 'call', type = 'function', ['function'] = { name = 'run_command', arguments = '{"argv":["echo","hello"]}' } },
} })
assert(requests[#requests].config.model == 'fast-model')
assert(requests[#requests].config.options.effort == 'low' and #requests[#requests].specs == 0)
reply('{"summary":"Print hello","safety_score":1}')
choose('review')
ask('Is it safe?', function(answer) assert(answer == 'Yes') end)
assert(requests[#requests].config.model == 'reasoning-model')
assert(requests[#requests].config.options.effort == 'high')
reply('Yes')
choose('reject')
assert(requests[#requests].config.model == baseline.models.openrouter)
local before = #requests
reply('Finished')
assert(vim.wait(1000, function() return #requests > before end, 10))
assert(requests[#requests].config.provider == 'copilot' and requests[#requests].config.model == 'long-model')
assert(requests[#requests].config.options.api_host == options.copilot.api_host)
reply('{"replacements":[]}')
plugin.compact(true)
assert(requests[#requests].config.model == 'long-model' and #requests[#requests].specs == 0)
reply('Summary')
plugin.history()
assert(requests[#requests].config.model == 'fast-model')
reply('Checked a tool.')
local id = history.list(workspace)[1].id
local chat = history.load(workspace, id)
assert(vim.deep_equal(chat.model_presets, presets))
local changed = plugin.get_settings()
changed.model_presets.fast.model = 'changed-fast'
assert(plugin.configure(changed))
assert(history.load(workspace, id).messages[2].content == 'Check a tool', 'preset-only changes preserve the chat')
assert(history.load(workspace, id).model_presets.fast.model == 'changed-fast')
plugin.new()
assert(plugin.configure(base))
assert(plugin.resume(id))
assert(plugin.get_settings().model_presets.fast.model == 'changed-fast')
chat.model_presets = nil
assert(history.save(workspace, 'legacy-presets', chat))
assert(plugin.resume('legacy-presets'))
assert(plugin.get_settings().model_presets.fast.model == 'changed-fast')
chat.model_presets = { fast = { model = false } }
assert(history.save(workspace, 'bad-presets', chat))
assert(plugin.resume('bad-presets'))
assert(plugin.get_settings().model_presets.fast.model == 'changed-fast')
chat.model_presets = {}
chat.secondary_models = { openrouter = 'obsolete-model' }
chat.context_summary, chat.compacted_until = nil, nil
assert(history.save(workspace, 'clear-presets', chat))
assert(plugin.resume('clear-presets'))
assert(vim.deep_equal(plugin.get_settings().model_presets, {}))
assert(plugin.get_settings().secondary_models == nil, 'obsolete chat settings must not be restored')
plugin.compact(true)
assert(requests[#requests].config.model == chat.model, 'obsolete chat fallback must not affect feature requests')
reply('Inherited main summary')
assert(history.load(workspace, 'clear-presets').secondary_models == nil, 'new chat saves omit obsolete settings')
assert(plugin.configure(base, 'global'))
changed = plugin.get_settings()
changed.model_presets = nil
assert(plugin.configure(changed), 'legacy configure calls preserve presets')
assert(vim.deep_equal(plugin.get_settings().model_presets, presets))
changed = plugin.get_settings()
changed.model_presets.fast.model = 'session-fast'
assert(plugin.configure(changed))
vim.fn.chdir(temp .. '/two')
assert(plugin.get_settings().model_presets.fast.model == 'fast-model', 'workspace changes reset session presets')
plugin.setup({ max_context_tokens = false })
assert(vim.deep_equal(plugin.get_settings().model_presets, presets), 'saved presets override setup')
-- Real picker: presets share the override controls and feature selection stays draft-only.
local picker = require('codeit.settings.picker')
local steps, inputs, applied, scope = {}, {}, nil, nil
vim.ui.input = function(_, callback) callback(table.remove(inputs, 1)) end
require('codeit.settings.menu').select = function(items, _, callback)
  local wanted = table.remove(steps, 1)
  for _, item in ipairs(items) do
    if (type(item) == 'table' and (item.slug or item.id or item.value or item.label) or item) == wanted then
      return callback(item)
    end
  end
  error('missing choice: ' .. tostring(wanted))
end
local function pick(current)
  applied = nil
  picker.show(current, function(values, selected_scope) applied, scope = values, selected_scope end)
  assert(#steps == 0 and #inputs == 0)
end
steps = { 'preset_fast', 'provider', 'copilot', 'model', 'picked-model', 'api_host', '',
  'back', 'tool_review', 'preset', 'fast', 'back', 'workspace' }
inputs = {}
pick(base)
assert(scope == 'workspace' and applied.model_presets.fast.model == 'picked-model')
assert(searches[#searches].provider == 'copilot' and searches[#searches].options.api_host == options.copilot.api_host)
assert(applied.model_presets.fast.options.api_host == '')
assert(applied.feature_settings.tool_review.preset == 'fast')
assert(settings.feature_config(applied, 'tool_review').model == 'picked-model')
assert(vim.deep_equal(base.model_presets, presets) and base.feature_settings.tool_review == nil)
steps = { 'preset_reasoning', 'preferred_provider', 'upstream', 'effort', '',
  'service_tier', '(inherit)', 'manual', 'back', 'global' }
inputs = { ' manual-reasoner ' }
pick(applied)
assert(scope == 'global' and endpoints[#endpoints] == 'reasoning-model')
assert(applied.model_presets.reasoning.model == 'manual-reasoner')
assert(applied.model_presets.reasoning.options.preferred_provider == 'upstream')
assert(applied.model_presets.reasoning.options.effort == '')
assert(applied.model_presets.reasoning.options.service_tier == nil)
steps = { 'tool_review', 'preset', '', 'back', 'session' }
pick(applied)
assert(applied.feature_settings.tool_review.preset == '')
assert(settings.feature_config(applied, 'tool_review').model == baseline.models.openrouter)
steps = { 'tool_review', 'preset', 'default', 'back', 'preset_reasoning', 'model_clear',
  'options_clear', 'back', 'session' }
pick(applied)
assert(applied.feature_settings.tool_review.preset == nil)
assert(applied.model_presets.reasoning.model == nil and applied.model_presets.reasoning.options == nil)
steps = { 'tool_review', 'preset', 'long_context', 'reset', 'back', 'preset_fast', 'reset', 'back', 'session' }
pick(applied)
assert(applied.feature_settings.tool_review == nil and applied.model_presets.fast == nil)
-- Cancel after draft edits without applying; a stale async model callback is ignored.
local held, did_apply = nil, false
require('codeit.settings.menu').select = function(_, _, callback) held = callback end
picker.show(base, function() did_apply = true end)
held({ id = 'preset_fast' })
held({ id = 'reset' })
held({ id = 'back' })
held(nil)
assert(not did_apply and vim.deep_equal(base.model_presets, presets))
local live, model_callback = true, nil
package.loaded['codeit.providers'].models = function(_, callback) model_callback = callback end
picker.show(base, function() did_apply = true end, function() return live end)
held({ id = 'preset_fast' })
held({ id = 'model' })
local prior = held
live = false
model_callback({ { id = 'stale-model' } })
assert(held == prior and not did_apply and base.model_presets.fast.model == 'fast-model')
vim.fn.delete(path)
vim.fn.delete(temp, 'rf')
print('codeit model presets tests passed')
