vim.opt.runtimepath:prepend(vim.fn.getcwd())
local root, temp = vim.fn.getcwd(), vim.fn.tempname()
vim.fn.mkdir(temp, 'p')
vim.fn.chdir(temp)
local history = require('codeit.chat.storage')
local requests, callbacks, metadata = {}, {}, {}
local feature_limit, long_limit, pending_metadata
package.loaded['codeit.providers'] = {
  chat = function(config, messages, specs, callback)
    requests[#requests + 1] = { config = vim.deepcopy(config), messages = vim.deepcopy(messages), specs = specs }
    callbacks[#callbacks + 1] = callback
  end,
  context_limit = function(config, callback)
    metadata[#metadata + 1] = config.model
    if pending_metadata and config.model == 'long-model' then
      pending_metadata.callback = callback
    elseif config.model == 'long-model' then
      callback(long_limit)
    else
      callback(feature_limit)
    end
  end,
}
local tools = require('codeit.tools')
local schemas = { { type = 'function' } }
tools.request_specs = function() return schemas end
require('codeit.tools.approval').prefetch = function() return nil end
tools.execute = function(_, _, _, callback) callback('ok') end
local plugin = require('codeit')
local function setup(extra)
  feature_limit, long_limit, pending_metadata = nil, nil, nil
  schemas = { { type = 'function' } }
  plugin.setup(vim.tbl_deep_extend('force', { system_prompt = 'system', context_review = false,
    max_context_tokens = false, feature_settings = { compaction = { model = 'compact' } } }, extra or {}))
end
local function reply(text, usage)
  callbacks[#callbacks]({ role = 'assistant', content = text }, nil, usage)
end
local function turn(question, answer)
  plugin.send(question)
  reply(answer or string.rep('a', 200))
end
local function saved()
  return history.load(history.workspace(), history.list(history.workspace())[1].id)
end
local function call(id)
  return { id = id, type = 'function', ['function'] = { name = 'mock', arguments = '{}' } }
end
-- Default manual compaction preserves the latest turn and skips tiny chats.
setup()
turn(string.rep('first', 100))
local before = #requests
plugin.compact()
assert(#requests == before)
turn('recent exact request', 'recent exact answer')
plugin.compact()
assert(#requests == before + 2 and #requests[#requests].specs == 0)
assert(not requests[#requests].messages[2].content:find('recent exact', 1, true))
assert(requests[#requests].config.max_output_tokens == 2560)
reply('Older task state.')
assert(saved().compacted_until == 3)
plugin.send('continue')
local current = requests[#requests].messages
assert(current[3].content == 'recent exact request' and current[4].content == 'recent exact answer')
reply('done')
vim.cmd('CodeitCompact!')
assert(requests[#requests].messages[2].content:find('recent exact request', 1, true))
reply('All task state.')
assert(saved().compacted_until == #saved().messages)
local stats = plugin.context_stats()
assert(#stats.compactions == 2 and stats.compactions[1].after_tokens < stats.compactions[1].before_tokens)
assert(stats.compactions[1].duration_ms >= 0 and stats.compactions[1].passes == 1)
local id = saved().id
plugin.resume(id)
assert(vim.deep_equal(stats, plugin.context_stats()))
-- Oversized and non-reducing results are rejected but still billed.
setup({ compaction = { summary_tokens = 64 } })
turn(string.rep('q', 800))
plugin.compact(true)
reply(string.rep('large', 200), { cost = 0.1, prompt_tokens = 100, completion_tokens = 100 })
assert(saved().compacted_until == nil and saved().cost == 0.1)
assert(plugin.context_stats().compactions[1].error:find('budget', 1, true))
setup()
turn('q', 'a')
plugin.compact(true)
reply('This adds more context than the source.')
assert(saved().context_summary == nil)
assert(plugin.context_stats().compactions[1].error:find('reduce', 1, true))
-- Private reasoning is never included in compaction input.
setup()
plugin.send(string.rep('q', 800))
callbacks[#callbacks]({ role = 'assistant', content = 'done', _copilot_reasoning = { encrypted_content = 'SECRET' } })
plugin.compact(true)
assert(not requests[#requests].messages[2].content:find('SECRET', 1, true))
reply('State.')
assert(saved().messages[3]._copilot_reasoning.encrypted_content == 'SECRET')
-- Smaller feature windows batch only at completed-turn boundaries and commit atomically.
setup()
for i = 1, 3 do turn(string.rep(tostring(i), 1300), string.rep('a', 700)) end
feature_limit = 1100
before = #requests
plugin.compact(true)
assert(#requests == before + 1)
assert(requests[#requests].messages[2].content:find(string.rep('1', 100), 1, true))
assert(not requests[#requests].messages[2].content:find(string.rep('2', 100), 1, true))
reply('First state.')
assert(saved().compacted_until == nil and #requests == before + 2)
assert(requests[#requests].messages[2].content:find('Previous summary:\nFirst state.', 1, true))
reply('Second state.')
assert(saved().compacted_until == nil and #requests == before + 3)
reply('Final state.')
assert(saved().compacted_until == 7 and plugin.context_stats().compactions[1].passes == 3)
setup()
for i = 1, 2 do turn(string.rep('q', 1300), string.rep('a', 700)) end
feature_limit = 1100
plugin.compact(true)
reply('Partial state.')
callbacks[#callbacks](nil, 'second batch failed')
assert(saved().compacted_until == nil and saved().context_summary == nil)
setup()
turn(string.rep('q', 10000))
feature_limit = 1100
before = #requests
plugin.compact(true)
assert(#requests == before and saved().context_summary == nil)
assert(plugin.context_stats().compactions[1].passes == 0)
-- Oversized compaction turns fail over only when the long-context preset fits.
local long_preset = { provider = 'copilot', model = 'long-model',
  options = { api_host = 'api.business.githubcopilot.com' } }
setup({ model_presets = { long_context = long_preset } })
turn(string.rep('q', 10000))
feature_limit, long_limit = 1100, 10000
before = #requests
plugin.compact(true)
assert(#requests == before + 1 and requests[#requests].config.model == 'long-model')
assert(requests[#requests].config.provider == 'copilot')
assert(requests[#requests].config.options.api_host == long_preset.options.api_host)
reply('Large turn state.')
assert(saved().context_summary == 'Large turn state.' and saved().compacted_until == 3)
-- A later oversized batch retains the earlier summary and commits atomically.
setup({ model_presets = { long_context = long_preset } })
turn(string.rep('q', 1300), string.rep('a', 700))
turn(string.rep('q', 10000))
feature_limit, long_limit = 1100, 10000
plugin.compact(true)
assert(requests[#requests].config.model == 'compact')
reply('First batch state.')
assert(requests[#requests].config.model == 'long-model' and saved().context_summary == nil)
assert(requests[#requests].messages[2].content:find('Previous summary:\nFirst batch state.', 1, true))
reply('Combined state.')
assert(saved().compacted_until == 5 and plugin.context_stats().compactions[1].passes == 2)
for _, fallback_limit in ipairs({ false, 1100 }) do
  setup({ model_presets = { long_context = long_preset } })
  turn(string.rep('q', 10000))
  feature_limit, long_limit = 1100, fallback_limit or nil
  before = #requests
  plugin.compact(true)
  assert(#requests == before and saved().context_summary == nil)
end
-- Remaining active context uses the preset for this user/tool turn only.
setup({ max_context_tokens = 1000, model_presets = { long_context = long_preset } })
long_limit = 10000
plugin.send(string.rep('active', 1000))
assert(requests[#requests].config.model == 'long-model' and requests[#requests].specs ~= 0)
callbacks[#callbacks]({ content = vim.NIL, tool_calls = { call('fallback-tool') } })
assert(requests[#requests].config.model == 'long-model')
reply('done')
plugin.compact(true)
reply('Small prior state.')
plugin.send('small new turn')
assert(requests[#requests].config.model == 'openai/gpt-4o-mini', 'failover must not change the main model')
reply('done')
-- Unavailable/insufficient metadata keeps the original best-effort request.
for _, fallback_limit in ipairs({ false, 1000 }) do
  setup({ max_context_tokens = 1000, model_presets = { long_context = long_preset } })
  long_limit = fallback_limit or nil
  plugin.send(string.rep('active', 1000))
  assert(requests[#requests].config.model == 'openai/gpt-4o-mini')
  reply('done')
end
-- Cancelled asynchronous lookups must not start fallback requests.
setup({ max_context_tokens = 1000, model_presets = { long_context = long_preset } })
pending_metadata = {}
before = #requests
plugin.send(string.rep('active', 1000))
local stale_callback = pending_metadata.callback
assert(stale_callback and #requests == before)
plugin.new()
stale_callback(10000)
assert(#requests == before)
setup({ model_presets = { long_context = long_preset } })
turn(string.rep('q', 10000))
feature_limit, pending_metadata = 1100, {}
before = #requests
plugin.compact(true)
stale_callback = pending_metadata.callback
assert(stale_callback and #requests == before)
plugin.new()
stale_callback(10000)
assert(#requests == before)
-- Tool schemas are included even when transcript growth is small.
setup({ max_context_tokens = 1000 })
turn(string.rep('q', 300))
schemas = { { description = string.rep('schema', 450) } }
plugin.send('next')
assert(#requests[#requests].specs == 0)
reply('Prior state.')
assert(#requests[#requests].specs == 1 and requests[#requests].messages[2].content:find('Prior state.', 1, true))
reply('done')
-- An oversized existing summary triggers the full-budget safety path.
setup({ max_context_tokens = 1000 })
turn(string.rep('q', 800))
plugin.compact(true)
reply('Small state.')
plugin.context()
local buf = vim.fn.bufnr('codeit://context')
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
for i, line in ipairs(lines) do
  if line == 'Small state.' then vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { string.rep('s', 3200) }); break end
end
vim.cmd('write')
vim.cmd('close')
plugin.send('active only')
assert(#requests[#requests].specs > 0, 'cannot recompact with no eligible newer completed turn')
reply('answer')
plugin.send('safety trigger')
assert(#requests[#requests].specs == 0, 'existing summary must count toward safety budget')
reply('Replacement state.')
assert(saved().context_summary == 'Replacement state.')
reply('done')
-- Observed main-input cache ratios exclude feature requests and missing metadata.
setup()
plugin.send('cache')
reply('cached', { cost = 0, prompt_tokens = 100, completion_tokens = 10, cached_tokens = 60 })
turn('unknown cache')
stats = plugin.context_stats()
assert(stats.cached_tokens == 60 and stats.cache_observed_tokens == 100 and stats.main_requests == 2)
local copy = plugin.context_stats()
copy.cached_tokens = 999
assert(plugin.context_stats().cached_tokens == 60)
-- Review commits during an active tool turn affect only the NEXT user turn.
setup({ context_review = true, context_review_min_tokens = 1 })
tools.execute = function(_, _, _, callback) callback(string.rep('tool output', 300)) end
plugin.send('first tool turn')
callbacks[#callbacks]({ content = vim.NIL, tool_calls = { call('old') } })
reply('done')
before = #requests
assert(vim.wait(1000, function() return #requests == before + 1 end, 10))
local review_callback = callbacks[#callbacks]
plugin.send('second tool turn')
review_callback({ content = '{"replacements":[{"tool_call_id":"old","summary":"Inspected prior state."}]}' })
assert(#saved().context_reviews == 1)
callbacks[#callbacks]({ content = vim.NIL, tool_calls = { call('new') } })
local continued = requests[#requests].messages
local found_old = false
for _, message in ipairs(continued) do
  if message.role == 'tool' and message.tool_call_id == 'old' then found_old = true end
end
assert(found_old, 'review must not rewrite the active tool-round prefix')
reply('done')
plugin.send('next turn')
local found_note = false
for _, message in ipairs(requests[#requests].messages) do
  if type(message.content) == 'string' and message.content:find('Inspected prior state.', 1, true) then found_note = true end
end
assert(found_note)
-- Policy configuration is validated.
for _, opts in ipairs({ { compaction = false }, { compaction = { summary_tokens = 0 } },
  { compaction = { manual_keep_turns = -1 } }, { compaction = { output_reserve = 0.5 } },
  { context_review_min_tokens = -1 } }) do assert(not pcall(plugin.setup, opts)) end
vim.fn.chdir(root)
vim.fn.delete(temp, 'rf')
print('codeit compaction policy tests passed')
