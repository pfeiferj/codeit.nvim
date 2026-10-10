vim.opt.runtimepath:prepend(vim.fn.getcwd())
local temp = vim.fn.tempname()
vim.fn.mkdir(temp, 'p')
vim.fn.chdir(temp)
local history = require('codeit.history')
local settings = require('codeit.settings')
local workspace = history.workspace()
local path = vim.fn.stdpath('data') .. '/codeit/settings.json'
vim.fn.delete(path)
local requests, callbacks, searches, endpoints = {}, {}, {}, {}
package.loaded['codeit.providers'] = {
  chat = function(config, messages, specs, callback)
    requests[#requests + 1] = { config = vim.deepcopy(config), messages = vim.deepcopy(messages), specs = specs }
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
local features = {
  tool_assessment = { provider = 'copilot', model = 'assessor', options = { api_host = 'api.business.githubcopilot.com' } },
  tool_review = { model = 'reviewer', options = { effort = 'high', service_tier = 'priority', preferred_provider = 'upstream' } },
  context_review = { provider = 'copilot', model = 'context-model' },
  history_summary = { model = 'history-model', options = { effort = 'minimal' } },
  compaction = { provider = 'copilot', model = 'compact-model' },
  cost_review = { model = 'cost-model' },
}
plugin.setup({ max_context_tokens = false, feature_settings = features,
  request_options = { openrouter = { effort = 'low', service_tier = 'flex' } } })
local base = plugin.get_settings()
assert(vim.deep_equal(base.feature_settings, features))
for _, name in ipairs(settings.features) do
  local result = settings.feature_config(base, name)
  assert(result.model == features[name].model)
end
local inherited = vim.deepcopy(base)
inherited.feature_settings = { compaction = { options = { service_tier = '', effort = '' } } }
local resolved = settings.feature_config(inherited, 'compaction', 'resumed-main')
assert(resolved.model == 'resumed-main' and resolved.options.service_tier == '' and resolved.options.effort == '')
inherited.feature_settings.compaction.provider = 'copilot'
inherited.feature_settings.compaction.options.api_host = 'api.business.githubcopilot.com'
resolved = settings.feature_config(inherited, 'compaction', 'resumed-main')
assert(resolved.model == base.models.copilot and resolved.options.effort == nil)
assert(resolved.options.api_host == 'api.business.githubcopilot.com')
assert(base.request_options.openrouter.effort == 'low', 'resolving overrides must not mutate defaults')
for _, bad in ipairs({ false, { unknown = {} }, { compaction = false },
  { compaction = { provider = 'unknown' } }, { compaction = { provider = false } },
  { compaction = { model = false } }, { compaction = { model = '   ' } },
  { compaction = { model = 'bad\nmodel' } }, { compaction = { unknown = true } },
  { compaction = { options = false } }, { compaction = { options = { unknown = '' } } },
  { compaction = { options = { effort = 'invalid' } } },
  { compaction = { options = { service_tier = 'invalid' } } },
  { compaction = { options = { api_host = 'attacker.example' } } },
  { compaction = { options = { preferred_provider = 'bad\nslug' } } },
}) do
  local invalid = vim.deepcopy(base)
  invalid.feature_settings = bad
  assert(not plugin.configure(invalid), 'invalid feature settings must be rejected')
  assert(not pcall(plugin.setup, invalid), 'setup must reject invalid feature settings')
end
plugin.setup({ max_context_tokens = false, context_review_min_tokens = 0, feature_settings = features,
  request_options = { openrouter = { effort = 'low', service_tier = 'flex' } } })
local function reply(content, usage)
  callbacks[#callbacks]({ role = 'assistant', content = content }, nil, usage)
end
plugin.send('Check a tool')
assert(requests[#requests].config.model == base.models.openrouter)
local prompt = require('codeit.approval_prompt')
local choose, ask
prompt.show = function(_, _, callback) choose = callback end
prompt.ask_reviewer = function(_, _, callback) ask = callback end
vim.ui.input = function(_, callback) callback('Not needed') end
callbacks[#callbacks]({ role = 'assistant', tool_calls = {
  { id = 'call', type = 'function', ['function'] = { name = 'run_command', arguments = '{"argv":["echo","hello"]}' } },
} })
assert(requests[#requests].config.provider == 'copilot' and requests[#requests].config.model == 'assessor')
assert(requests[#requests].config.options.api_host == 'api.business.githubcopilot.com')
assert(#requests[#requests].specs == 0)
reply('{"summary":"Print hello","safety_score":1}')
choose('review')
ask('Is it safe?', function(answer) assert(answer == 'Yes') end)
assert(requests[#requests].config.model == 'reviewer')
assert(requests[#requests].config.options.effort == 'high' and requests[#requests].config.options.service_tier == 'priority')
assert(requests[#requests].config.options.preferred_provider == 'upstream')
assert(#requests[#requests].specs == 2)
reply('Yes', { cost = 0.25, prompt_tokens = 10, completion_tokens = 5 })
choose('reject')
assert(requests[#requests].config.model == base.models.openrouter)
reply('Finished', { cost = 0, prompt_tokens = 20, completion_tokens = 5 })
local before = #requests
assert(vim.wait(1000, function() return #requests > before end, 10))
assert(requests[#requests].config.provider == 'copilot' and requests[#requests].config.model == 'context-model')
reply('{"replacements":[]}')
local id = history.list(workspace)[1].id
local chat = history.load(workspace, id)
assert(chat.cost == 0.25 and chat.missing_cost == 3, 'missing Copilot feature usage must also be tracked')
plugin.compact(true)
assert(requests[#requests].config.provider == 'copilot' and requests[#requests].config.model == 'compact-model')
reply('Summary')
plugin.history()
assert(requests[#requests].config.model == 'history-model' and requests[#requests].config.options.effort == 'minimal')
reply('Checked a tool.')
assert(vim.deep_equal(history.load(workspace, id).feature_settings, features))
local changed = plugin.get_settings()
changed.feature_settings.compaction = { model = 'new-compact' }
assert(plugin.configure(changed))
assert(history.load(workspace, id).messages[2].content == 'Check a tool', 'feature-only changes preserve the chat')
plugin.new()
assert(plugin.configure(base))
assert(plugin.resume(id))
assert(plugin.get_settings().feature_settings.compaction.model == 'new-compact')
chat.feature_settings = nil
assert(history.save(workspace, 'legacy-feature', chat))
assert(plugin.resume('legacy-feature'))
assert(plugin.get_settings().feature_settings.compaction.model == 'new-compact', 'old chats inherit current features')
chat.feature_settings = { compaction = { model = false } }
assert(history.save(workspace, 'bad-feature', chat))
assert(plugin.resume('bad-feature'))
assert(plugin.get_settings().feature_settings.compaction.model == 'new-compact')
local legacy = vim.deepcopy(base)
legacy.feature_settings = nil
assert(settings.save(legacy, 'global', workspace))
assert(vim.deep_equal(settings.resolve(base, workspace).feature_settings, features))
legacy.feature_settings = {}
assert(settings.save(legacy, 'global', workspace))
assert(vim.deep_equal(settings.resolve(base, workspace).feature_settings, {}))
assert(settings.save(base, 'global', workspace))
local scoped = vim.deepcopy(base)
scoped.feature_settings.compaction.model = 'workspace-compact'
assert(settings.save(scoped, 'workspace', workspace))
assert(settings.resolve(base, workspace).feature_settings.compaction.model == 'workspace-compact')
local legacy_call = plugin.get_settings()
legacy_call.feature_settings = nil
assert(plugin.configure(legacy_call))
assert(plugin.get_settings().feature_settings.compaction.model == 'new-compact')
-- OpenRouter feature costs are tracked even with a Copilot main chat.
vim.fn.delete(path)
plugin.setup({ provider = 'copilot', max_context_tokens = false, context_review = false,
  feature_settings = { compaction = { provider = 'openrouter', model = 'paid-summary' } } })
plugin.open()
plugin.send('Copilot main' .. string.rep(' details', 30))
reply('Done', { cost = 0, prompt_tokens = 40, completion_tokens = 5, total_tokens = 45 })
plugin.compact(true)
assert(requests[#requests].config.provider == 'openrouter')
reply('Paid summary', { cost = 0.5, prompt_tokens = 100, completion_tokens = 20 })
chat = history.load(workspace, history.list(workspace)[1].id)
assert(chat.cost == 0.5 and chat.missing_cost == 0)
assert(table.concat(vim.api.nvim_buf_get_lines(vim.fn.bufnr('codeit://chat'), 0, -1, false), '\n'):find('Cost: $0.5', 1, true))
-- Drive feature menus with the real picker; all edits remain draft-only until apply.
local picker = require('codeit.settings_picker')
local steps, inputs, applied = {}, {}, nil
vim.ui.input = function(_, callback) callback(table.remove(inputs, 1)) end
require('codeit.settings_menu').select = function(items, _, callback)
  local wanted = table.remove(steps, 1)
  for _, item in ipairs(items) do
    if (type(item) == 'table' and (item.slug or item.id or item.value or item.label) or item) == wanted then
      return callback(item)
    end
  end
  error('missing choice: ' .. tostring(wanted))
end
steps = { 'compaction', 'provider', 'copilot', 'api_host', 'api.business.githubcopilot.com',
  'model', 'picked-model', 'back', 'session' }
inputs = {}
picker.show(base, function(values) applied = values end)
assert(searches[#searches].provider == 'copilot')
assert(searches[#searches].options.api_host == 'api.business.githubcopilot.com')
assert(applied.feature_settings.compaction.model == 'picked-model')
assert(base.feature_settings.compaction.model == 'compact-model')
steps = { 'tool_review', 'model', 'picked-model', 'preferred_provider', 'upstream',
  'effort', 'xhigh', 'service_tier', '', 'back', 'workspace' }
inputs = {}
picker.show(applied, function(values) applied = values end)
assert(endpoints[#endpoints] == 'picked-model', 'upstream lookup must use the feature model')
assert(applied.feature_settings.tool_review.options.effort == 'xhigh')
assert(applied.feature_settings.tool_review.options.service_tier == '')
steps = { 'tool_review', 'effort', '(inherit)', 'preferred_provider', 'inherit', 'manual',
  'model_clear', 'back', 'compaction', 'reset', 'back', 'global' }
inputs = { ' manual-model ' }
picker.show(applied, function(values) applied = values end)
assert(applied.feature_settings.tool_review.model == nil)
assert(applied.feature_settings.tool_review.options.effort == nil)
assert(applied.feature_settings.tool_review.options.preferred_provider == nil)
assert(applied.feature_settings.compaction == nil)
steps = { 'tool_review', 'options_clear', 'back', 'session' }
picker.show(applied, function(values) applied = values end)
assert(applied.feature_settings.tool_review.options == nil)
-- A stale callback inside a feature submenu must not mutate/apply a draft.
local held, live, did_apply = nil, true, false
require('codeit.settings_menu').select = function(_, _, callback) held = callback end
picker.show(base, function() did_apply = true end, function() return live end)
held({ id = 'compaction' })
held({ id = 'provider' })
live = false
held('openrouter')
assert(not did_apply)
vim.fn.delete(temp, 'rf')
print('codeit feature settings tests passed')
