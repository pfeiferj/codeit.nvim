vim.opt.runtimepath:prepend(vim.fn.getcwd())
local defer = vim.defer_fn
local logs = {}
package.loaded['codeit.providers.log'] = {
  error = function(config, err, detail)
    logs[#logs + 1] = { config = config, err = err, detail = detail }
  end,
}
local implementations = {}
for _, name in ipairs({ 'openai', 'openrouter', 'copilot', 'codex' }) do
  implementations[name] = {}
  package.loaded['codeit.providers.' .. name] = implementations[name]
end
local providers = require('codeit.providers')
local missing = 'Response has no assistant message'
local answer = { role = 'assistant', content = 'Recovered' }
local billing = { prompt_tokens = 12, completion_tokens = 4 }
local call = { id = 'call_2', type = 'function', ['function'] = { name = 'read_file', arguments = '{}' } }
local messages = {
  { role = 'user', content = 'hello' },
  { role = 'assistant', tool_calls = { call } },
  { role = 'tool', tool_call_id = call.id, content = 'Already executed' },
}
local tools = { { type = 'function', ['function'] = { name = 'read_file' } } }
local function start(entries, options)
  options = options or {}
  logs = {}
  local state = { calls = 0, callbacks = 0, active = options.active ~= false, timers = {}, previews = {} }
  local config = { provider = options.provider or 'openai', model = 'test', max_output_tokens = 256 }
  local function active() return state.active end
  local function activity() state.activity = (state.activity or 0) + 1 end
  vim.defer_fn = function(fn, delay)
    state.timers[#state.timers + 1] = { fn = fn, delay = delay }
  end
  implementations[config.provider].chat = function(selected, transcript, specs, callback, on_text, is_active, on_activity)
    state.calls = state.calls + 1
    assert(selected == config and transcript == messages and specs == tools, 'recovery must reuse the original request')
    assert(is_active == active and on_activity == activity, 'cancellation and activity callbacks must survive recovery')
    assert((on_text ~= nil) == (options.streaming == true), 'recovery must preserve streaming mode')
    local entry = assert(entries[state.calls], 'unexpected retry')
    if entry.preview then on_text(entry.preview) end
    on_activity()
    if entry.cancel then state.active = false end
    state.preview = on_text
    callback(entry.message, entry.err, entry.usage, entry.detail)
  end
  providers.chat(config, messages, tools, function(message, err, usage)
    state.callbacks = state.callbacks + 1
    state.message, state.err, state.usage = message, err, usage
  end, options.streaming and function(text) state.previews[#state.previews + 1] = text end or nil, active, activity)
  return state
end
local function retry(state)
  assert(#state.timers == 1 and state.timers[1].delay == 1000, 'recovery must schedule one bounded delay')
  state.timers[1].fn()
end
for _, provider in ipairs({ 'openai', 'openrouter', 'copilot', 'codex' }) do
  for _, streaming in ipairs({ false, true }) do
    local state = start({
      { err = missing, detail = 'empty response' },
      { message = answer, usage = billing, preview = streaming and 'Recovered' or nil },
    }, { provider = provider, streaming = streaming })
    assert(state.calls == 1 and state.callbacks == 0, 'recoverable failure must not reach the caller yet')
    retry(state)
    assert(state.calls == 2 and state.callbacks == 1 and state.message == answer and not state.err)
    assert(state.usage == billing and state.activity == 2)
    assert(#logs == 1 and logs[1].err == missing and logs[1].detail == 'empty response', 'keep failed attempts in the error log')
    if streaming then
      assert(vim.deep_equal(state.previews, { 'Recovered' }))
      state.preview('late text')
      assert(#state.previews == 1, 'ignore previews after completion')
    end
  end
end
local state = start({ { err = missing }, { err = missing, detail = 'still empty' } })
retry(state)
assert(state.calls == 2 and #state.timers == 1 and state.callbacks == 1, 'never retry indefinitely')
assert(not state.message and state.err == missing and #logs == 2 and logs[2].detail == 'still empty')
state = start({ { err = missing }, { err = 'HTTP 500: unavailable' } })
retry(state)
assert(state.callbacks == 1 and state.err == 'HTTP 500: unavailable', 'report the final attempt failure')
for _, err in ipairs({ 'HTTP 401: unauthorized', 'Invalid JSON response', 'Summary output reached its token cap',
  'Copilot response incomplete: max_output_tokens', 'Streaming response ended before completion' }) do
  state = start({ { err = err } })
  assert(state.calls == 1 and state.callbacks == 1 and state.err == err and #state.timers == 0)
end
state = start({ { err = missing, preview = 'Partial answer' } }, { streaming = true })
assert(state.callbacks == 1 and state.err == missing and #state.timers == 0, 'never replace a visible partial answer')
state = start({ { err = missing, preview = '' }, { message = answer } }, { streaming = true })
retry(state)
assert(state.message == answer, 'empty streaming deltas do not prevent recovery')
state = start({ { message = { role = 'assistant', tool_calls = { call } } } })
assert(state.calls == 1 and state.callbacks == 1 and #state.timers == 0, 'tool-only responses must not be retried')
state = start({}, { active = false })
assert(state.calls == 0 and state.callbacks == 0 and #state.timers == 0)
state = start({ { err = missing } })
state.active = false
retry(state)
assert(state.calls == 1 and state.callbacks == 0, 'cancellation while waiting must prevent the retry')
state = start({ { err = missing }, { message = answer, cancel = true } })
retry(state)
assert(state.calls == 2 and state.callbacks == 0, 'cancellation during recovery must suppress the result')
vim.defer_fn = defer
print('codeit provider recovery tests passed')
