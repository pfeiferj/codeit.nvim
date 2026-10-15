vim.opt.runtimepath:prepend(vim.fn.getcwd())
local system, now_fn, new_timer = vim.system, vim.uv.now, vim.uv.new_timer
local now, state
vim.uv.now = function() return now end
vim.uv.new_timer = function()
  local timer = { closed = false }
  function timer:start(_, _, callback) self.tick = callback end
  function timer:stop() self.stopped = true end
  function timer:close() self.closed = true end
  state.timers[#state.timers + 1] = timer
  return timer
end
package.loaded['codeit.ui.approval_queue'] = { enqueue = function(show, live, on_error)
  local entry = { live = live, on_error = on_error }
  entry.show = function() entry.shown = true; show() end
  state.queued[#state.queued + 1] = entry
  if not state.hold_prompt then entry.show() end
  return function() entry.cancelled = true end
end }
package.loaded['codeit.tools.approval.prompt'] = { show = function(text, options, callback)
  local prompt = { text = text, callback = callback, options = options, closed = false }
  state.prompts[#state.prompts + 1] = prompt
  local function close()
    if prompt.closed then return end
    prompt.closed = true
    callback(nil)
  end
  return function(updated) prompt.text = updated end, close
end }
vim.system = function(args, options, callback)
  local call = { args = args, options = options, callback = callback, kills = 0 }
  state.calls[#state.calls + 1] = call
  return { kill = function(_, signal)
    assert(signal == 9)
    call.kills = call.kills + 1
  end }
end
local http = require('codeit.providers.http')
local function start(options)
  options = options or {}
  now = 0
  state = { timers = {}, calls = {}, prompts = {}, queued = {}, callbacks = 0,
    active = true, hold_prompt = options.hold_prompt, activity = 0, previews = {} }
  local function done(value, err)
    state.callbacks = state.callbacks + 1
    state.value, state.err = value, err
  end
  if options.metadata then
    http.get('https://example.com/models', {}, done)
  else
    local streaming = options.streaming and { responses = options.responses, on_text = function(text)
      state.previews[#state.previews + 1] = text
    end, on_activity = function() state.activity = state.activity + 1 end } or nil
    local active
    if not options.no_active then active = function() return state.active end end
    http.post('https://example.com/chat', {}, { model = 'test-model' }, done, streaming, active)
  end
  return state
end
local function advance(ms)
  now = ms
  for _, timer in ipairs(state.timers) do
    if not timer.closed then timer.tick() end
  end
  vim.wait(10)
end
local function complete(stdout, code)
  state.calls[#state.calls].callback({ code = code or 0, stdout = stdout, stderr = '' })
  vim.wait(10)
end
local function choose(id)
  local prompt = state.prompts[#state.prompts]
  prompt.closed = true
  prompt.callback(id)
end
local function cleaned()
  for _, timer in ipairs(state.timers) do assert(timer.closed, 'request timer leaked') end
  for _, entry in ipairs(state.queued) do assert(entry.cancelled or entry.shown, 'queued prompt leaked') end
  for _, prompt in ipairs(state.prompts) do assert(prompt.closed, 'visible prompt leaked') end
end

local s = start()
assert(vim.tbl_contains(s.calls[1].args, '--connect-timeout'))
local max_time = assert(vim.fn.index(s.calls[1].args, '--max-time')) + 1
assert(s.calls[1].args[max_time + 1] == '0', 'curl must not terminate an approved extension')
advance(209999)
assert(#s.prompts == 0)
advance(210000)
assert(#s.prompts == 1 and s.prompts[1].text:find('test-model', 1, true))
assert(s.prompts[1].options[1].id == 'stop', 'Enter must not approve an extension by default')
choose('extend')
advance(240000)
assert(s.calls[1].kills == 0 and #s.calls == 1 and s.callbacks == 0, 'extend must preserve the live process')
complete('{"answer":"ok"}\n200')
assert(s.callbacks == 1 and s.value.answer == 'ok' and not s.err)
cleaned()

s = start({ no_active = true })
advance(210000)
choose('extend')
advance(329999)
assert(#s.prompts == 1)
advance(330000)
assert(#s.prompts == 2, 'each subsequent extension requires new approval')
choose('extend')
advance(450000)
assert(#s.prompts == 3)
advance(480000)
assert(s.callbacks == 1 and s.err:find('timed out', 1, true) and s.calls[1].kills == 1)
assert(#s.calls == 1, 'expiry must not retry the provider request')
cleaned()

for _, choice in ipairs({ 'stop', 'dismiss' }) do
  s = start()
  advance(210000)
  choose(choice == 'stop' and 'stop' or nil)
  assert(s.callbacks == 1 and s.err:find('declined', 1, true) and s.calls[1].kills == 1)
  complete('{}\n200')
  assert(s.callbacks == 1, 'late process completion must not deliver twice')
  cleaned()
end

s = start()
advance(210000)
now = 240000
choose('extend')
assert(s.callbacks == 1 and s.err:find('timed out', 1, true), 'late approval must not revive the request')
cleaned()

for _, held in ipairs({ false, true }) do
  s = start({ hold_prompt = held })
  advance(210000)
  advance(240000)
  assert(s.calls[1].kills == 1 and s.callbacks == 1 and s.err:find('timed out', 1, true))
  local entry = s.queued[1]
  assert(not entry.live())
  entry.show()
  assert(#s.prompts == (held and 0 or 1), 'expired queued prompts must never appear')
  cleaned()
end

for _, held in ipairs({ false, true }) do
  s = start({ hold_prompt = held })
  advance(210000)
  complete('{"answer":"done"}\n200')
  assert(s.callbacks == 1 and s.value.answer == 'done' and s.calls[1].kills == 0)
  cleaned()
end

for _, held in ipairs({ false, true }) do
  s = start({ hold_prompt = held })
  advance(210000)
  s.active = false
  advance(210050)
  assert(s.calls[1].kills == 1 and s.callbacks == 0, 'cancellation should not deliver an error')
  complete('{}\n200')
  assert(s.callbacks == 0)
  cleaned()
end

s = start({ hold_prompt = true })
advance(210000)
s.queued[1].on_error('test failure')
assert(s.callbacks == 1 and s.err:find('Could not show', 1, true) and s.calls[1].kills == 1)
cleaned()

-- Count meaningful SSE activity, not headers or keepalive traffic, for both APIs.
for _, responses in ipairs({ false, true }) do
  s = start({ streaming = true, responses = responses })
  local stdout = s.calls[1].options.stdout
  stdout(nil, 'HTTP/2 200\r\nContent-Type: text/event-stream\r\n\r\n: heartbeat\n\n')
  vim.wait(10)
  advance(200000)
  local event = responses and { type = 'response.reasoning_summary_text.delta', delta = 'Thinking' }
    or { choices = { { delta = { reasoning_details = { { index = 0, type = 'reasoning.text', text = 'Thinking' } } } } } }
  stdout(nil, 'data: ' .. vim.json.encode(event) .. '\n\n')
  vim.wait(10)
  assert(s.activity == 1 and #s.previews == 0)
  advance(210000)
  assert(s.prompts[1].text:find('Last response activity: 10 seconds ago.', 1, true))
  advance(211000)
  assert(s.prompts[1].text:find('Last response activity: 11 seconds ago.', 1, true), 'prompt must update while open')
  choose('extend')
  stdout(nil, 'data: ' .. vim.json.encode(responses
    and { type = 'response.output_text.delta', delta = 'Answer' }
    or { choices = { { delta = { content = 'Answer' } } } }) .. '\n\n')
  local terminal = responses and ('data: ' .. vim.json.encode({ type = 'response.completed', response = {
    status = 'completed', output = { { type = 'message', role = 'assistant',
      content = { { type = 'output_text', text = 'Answer' } } } },
  } }) .. '\n\n') or 'data: [DONE]\n\n'
  stdout(nil, terminal .. '\n200')
  complete('')
  assert(s.callbacks == 1 and not s.err and s.previews[#s.previews] == 'Answer')
  assert(#s.calls == 1 and s.calls[1].kills == 0, 'extension must retain streaming parser state')
  cleaned()
end

s = start({ metadata = true })
assert(#s.timers == 0)
local args = s.calls[1].args
assert(args[vim.fn.index(args, '--max-time') + 2] == '60', 'metadata timeout must remain unchanged')
complete('{"data":[]}\n200')
assert(s.callbacks == 1 and not s.err and #s.prompts == 0)
vim.system, vim.uv.now, vim.uv.new_timer = system, now_fn, new_timer
print('codeit provider deadline tests passed')
