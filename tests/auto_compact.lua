vim.opt.runtimepath:prepend(vim.fn.getcwd())
local temp = vim.fn.tempname()
vim.fn.mkdir(temp, 'p')
vim.fn.chdir(temp)
local history = require('codeit.history')
local workspace = history.workspace()
local requests, callbacks = {}, {}
package.loaded['codeit.providers'] = {
  chat = function(config, messages, specs, callback)
    requests[#requests + 1] = { config = vim.deepcopy(config), messages = vim.deepcopy(messages), specs = specs }
    callbacks[#callbacks + 1] = callback
  end,
}
-- Small synthetic windows need small synthetic schemas as well.
require('codeit.tools').request_specs = function() return { { type = 'function' } } end
local plugin = require('codeit')
plugin.setup({ system_prompt = 'system', max_context_tokens = 400,
  feature_settings = { compaction = { provider = 'copilot', model = 'compact-model',
    options = { api_host = 'api.business.githubcopilot.com' } } } })
local user = string.rep('u', 180)
local answer = string.rep('a', 180)
local function respond(index)
  callbacks[index]({ role = 'assistant', content = answer })
end
for i = 1, 3 do
  plugin.send(user .. i)
  assert(#requests == i, 'must not compact before threshold')
  respond(i)
end
local chat_id = history.list(workspace)[1].id
plugin.send(user .. '4')
assert(#requests == 4 and #requests[4].specs == 0, 'compaction must precede main request')
assert(requests[4].config.model == 'compact-model' and requests[4].config.provider == 'copilot',
  'automatic compaction uses the independent feature model/backend')
assert(requests[4].config.options.api_host == 'api.business.githubcopilot.com')
local first = requests[4].messages[2].content
assert(first:find('Previous summary', 1, true) == nil)
assert(first:find(user .. '1', 1, true) and first:find(user .. '2', 1, true))
assert(not first:find(user .. '3', 1, true), 'newest complete turn must be retained')
local previous = history.load(workspace, chat_id)
assert(previous.compacted_until == nil, 'checkpoint is not committed before summary succeeds')
local long_summary = 'Useful bounded summary'
callbacks[4]({ role = 'assistant', content = long_summary }, nil, { cost = 0.25 })
local saved = history.load(workspace, chat_id)
assert(saved.compacted_until == 5 and saved.context_summary == long_summary)
assert(saved.turn_costs[4].cost == 0.25 and saved.turn_costs[3].cost == 0,
  'automatic compaction must bill the active user turn')
assert(#requests == 5 and #requests[5].messages == 5)
assert(requests[5].config.model == 'openai/gpt-4o-mini', 'main request keeps the main model after compaction')
assert(requests[5].messages[2].content:find(long_summary, 1, true))
assert(requests[5].messages[3].content == user .. '3')
assert(requests[5].messages[5].content == user .. '4')
respond(5)
plugin.send(user .. '5')
assert(#requests == 6 and #requests[6].specs ~= 0, 'bounded summary should leave room for another turn')
respond(6)
plugin.send(user .. '6')
assert(#requests == 7 and #requests[7].specs == 0)
local second = requests[7].messages[2].content
assert(second:find('Previous summary:', 1, true) and second:find(long_summary, 1, true))
assert(second:find(user .. '3', 1, true) and not second:find(user .. '1', 1, true))
callbacks[7]({ role = 'assistant', content = 'replacement' })
saved = history.load(workspace, chat_id)
assert(saved.context_summary == 'replacement' and saved.compacted_until == 9)
assert(#requests == 8 and requests[8].messages[2].content:find('replacement', 1, true))
assert(not requests[8].messages[2].content:find(long_summary, 1, true))
assert(requests[8].messages[3].content == user .. '5')
respond(8)
plugin.resume(chat_id)
plugin.send('small')
assert(#requests == 9 and requests[9].messages[2].content:find('replacement', 1, true))
callbacks[9]({ role = 'assistant', content = 'ok' })
-- A failed automatic summary must leave the checkpoint alone and still send the question.
plugin.new()
for i = 1, 3 do
  plugin.send(user .. i)
  respond(#requests)
end
plugin.send(user .. '4')
local failed = #requests
assert(#requests[failed].specs == 0)
callbacks[failed](nil, 'temporary error')
assert(#requests == failed + 1 and requests[#requests].messages[2].content == user .. '1')
assert(history.load(workspace, history.list(workspace)[1].id).context_summary == nil)
respond(#requests)
-- Tool calls and results from the active turn must remain intact across compaction.
plugin.new()
for i = 1, 2 do
  plugin.send(user .. i)
  respond(#requests)
end
local tools = require('codeit.tools')
local execute = tools.execute
local approval = require('codeit.approval')
local prefetch = approval.prefetch
approval.prefetch = function() return nil end
tools.execute = function(_, _, _, callback) callback(string.rep('t', 500)) end
plugin.send('active task')
local tool_request = #requests
callbacks[tool_request]({ role = 'assistant', content = vim.NIL, tool_calls = {
  { id = 'call-1', type = 'function', ['function'] = { name = 'mock', arguments = '{}' } },
} })
local compact_request = #requests
assert(compact_request == tool_request + 1 and #requests[compact_request].specs == 0,
  'tool=' .. tool_request .. ' compact=' .. compact_request .. ' specs=' .. #requests[compact_request].specs)
assert(requests[compact_request].messages[2].content:find(user .. '1', 1, true))
callbacks[compact_request]({ role = 'assistant', content = 'tool summary' })
local continued = requests[#requests].messages
assert(continued[2].content:find('tool summary', 1, true))
assert(continued[3].content == 'active task' and continued[4].tool_calls[1].id == 'call-1')
assert(continued[5].role == 'tool' and #continued[5].content == 500)
tools.execute = execute
approval.prefetch = prefetch
-- With no override, resolve the selected model before determining the threshold.
local provider = require('codeit.providers')
local metadata_callbacks = {}
provider.context_limit = function(config, callback)
  if config.model == 'compact-model' then return callback(4000) end
  metadata_callbacks[#metadata_callbacks + 1] = { model = config.model, callback = callback }
end
plugin.setup({ system_prompt = 'system', model_presets = { long_context = { model = 'compact-model' } } })
local before = #requests
plugin.send(user .. '1')
assert(#requests == before and #metadata_callbacks == 1)
assert(metadata_callbacks[1].model == 'openai/gpt-4o-mini', 'threshold detection still uses the main model')
metadata_callbacks[1].callback(400)
assert(#requests == before + 1)
respond(#requests)
for i = 2, 3 do
  plugin.send(user .. i)
  metadata_callbacks[#metadata_callbacks].callback(400)
  respond(#requests)
end
plugin.send(user .. '4')
metadata_callbacks[#metadata_callbacks].callback(400)
assert(#requests == before + 4 and #requests[#requests].specs == 0)
plugin.new() -- cancel the pending summary
local stale_count = #requests
plugin.send('new task')
metadata_callbacks[#metadata_callbacks - 1].callback(400) -- stale callback from the old chat
assert(#requests == stale_count)
metadata_callbacks[#metadata_callbacks].callback(400)
assert(#requests == stale_count + 1)
respond(#requests)
plugin.new()
local no_limit_count = #requests
plugin.send('metadata unavailable')
metadata_callbacks[#metadata_callbacks].callback(nil, 'unavailable')
assert(#requests == no_limit_count + 1 and requests[#requests].messages[2].content == 'metadata unavailable')
respond(#requests)
plugin.setup({ system_prompt = 'system', max_context_tokens = 400 })
local lookups_before_override = #metadata_callbacks
plugin.send('manual override')
assert(#metadata_callbacks == lookups_before_override and #requests[#requests].specs ~= 0)
respond(#requests)
plugin.setup({ system_prompt = 'system', max_context_tokens = false })
local lookups = #metadata_callbacks
for i = 1, 4 do
  plugin.send(user .. i)
  assert(#metadata_callbacks == lookups)
  assert(#requests[#requests].specs ~= 0, 'disabled auto-compaction must never summarize')
  respond(#requests)
end
vim.fn.delete(temp, 'rf')
print('codeit automatic compaction tests passed')
