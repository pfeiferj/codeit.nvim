vim.opt.runtimepath:prepend(vim.fn.getcwd())
local stream = require('codeit.stream')
local function event(value)
  return 'data: ' .. (type(value) == 'string' and value or vim.json.encode(value)) .. '\r\n\r\n'
end
local header = 'HTTP/1.1 200 Connection established\r\n\r\nHTTP/2 200\r\nContent-Type: text/event-stream\r\n\r\n'
local function chat(delta, finish)
  return event({ choices = { { index = 0, delta = delta, finish_reason = finish } } })
end
local previews = {}
local parser = stream.new(false, function(text) previews[#previews + 1] = text end)
local wire = header .. ': heartbeat\r\n\r\n' .. chat({ content = 'hé' }) .. chat({ content = 'llo' })
  .. chat({ tool_calls = { { index = 0, id = 'call_1', type = 'function',
    ['function'] = { name = 'read_', arguments = '{"pa' } } } })
  .. chat({ tool_calls = { { index = 0, ['function'] = { name = 'file', arguments = 'th":"a"}' } },
    { index = 1, id = 'call_2', ['function'] = { name = 'other', arguments = '{}' } } } })
  .. chat({ reasoning_details = { { index = 0, type = 'reasoning.text', text = 'one' } } })
  .. chat({ reasoning_details = { { index = 0, type = 'reasoning.text', text = 'two' } } }, 'tool_calls')
  .. event({ choices = {}, usage = { prompt_tokens = 12, completion_tokens = 6, total_tokens = 18 } })
  .. event('[DONE]') .. '\n200'
-- Exercise every possible chunk boundary, including CRLF and UTF-8 splits.
for i = 1, #wire do parser.push(wire:sub(i, i)) end
local result, err, streamed = parser.finish()
assert(streamed and not err and result.choices[1].message.content == 'héllo')
local message = result.choices[1].message
assert(message.tool_calls[1]['function'].name == 'read_file')
assert(message.tool_calls[1]['function'].arguments == '{"path":"a"}')
assert(message.tool_calls[2].id == 'call_2')
assert(message.reasoning_details[1].text == 'onetwo')
assert(result.usage.total_tokens == 18 and previews[#previews] == 'héllo')
parser = stream.new(false, function() end)
parser.push(header .. chat({ refusal = 'No' }) .. chat({ refusal = ' thanks' }, 'stop') .. event('[DONE]'))
result, err = parser.finish()
assert(not err and result.choices[1].message.refusal == 'No thanks')
for _, tail in ipairs({ chat({ content = 'partial' }), 'data: {invalid}\n\n', event({ error = { message = 'oops' } }) }) do
  parser = stream.new(false, function() end)
  parser.push(header .. tail)
  result, err = parser.finish()
  assert(not result and err)
end
local final = { status = 'completed', output = {
  { type = 'message', role = 'assistant', content = { { type = 'output_text', text = 'Answer' } } },
  { type = 'function_call', call_id = 'call', name = 'read_file', arguments = '{}' },
  { type = 'reasoning', encrypted_content = 'encrypted' },
}, usage = { input_tokens = 4, output_tokens = 5 } }
parser = stream.new(true, function(text) previews[#previews + 1] = text end)
parser.push(header .. event({ type = 'response.output_text.delta', delta = 'Ans' }))
parser.push(event({ type = 'response.output_text.delta', delta = 'wer' })
  .. event({ type = 'response.completed', response = final }))
result, err = parser.finish()
assert(not err and vim.deep_equal(result, final) and previews[#previews] == 'Answer')
local normalized = require('codeit.copilot_responses').message(result)
assert(normalized.tool_calls[1].id == 'call' and normalized._copilot_reasoning[1].encrypted_content == 'encrypted')
parser = stream.new(true, function() end)
parser.push(header .. event({ type = 'response.output_text.delta', delta = 'partial' }) .. event('[DONE]'))
assert(select(2, parser.finish()), 'Responses requires its terminal response, not just DONE')

local system, defer = vim.system, vim.defer_fn
vim.env.OPENROUTER_API_KEY = 'test'
local attempts, waits, body, live, done = 0, {}, nil, {}, 0
vim.defer_fn = function(fn, ms) waits[#waits + 1] = ms; vim.schedule(fn) end
vim.system = function(args, options, callback)
  attempts = attempts + 1
  assert(vim.tbl_contains(args, '--no-buffer'))
  body = vim.json.decode(options.stdin)
  local response = attempts == 1 and 'HTTP/2 429\r\nRetry-After: 0\r\n\r\nToo many\n429'
    or header .. chat({ content = 'Hello' }) .. chat({}, 'stop')
      .. event({ choices = {}, usage = { total_tokens = 9 } }) .. event('[DONE]') .. '\n200'
  options.stdout(nil, response)
  vim.schedule(function()
    if attempts == 2 then assert(live[#live] == 'Hello' and done == 0, 'preview must precede completion') end
    callback({ code = 0 })
  end)
end
require('codeit.providers').chat({ provider = 'openrouter', model = 'test' }, {}, {}, function(value, failure, usage)
  assert(not failure and value.content == 'Hello' and usage.total_tokens == 9)
  done = done + 1
end, function(text) live[#live + 1] = text end)
assert(vim.wait(2000, function() return done > 0 end))
assert(done == 1 and attempts == 2 and waits[1] == 0 and body.stream and body.stream_options.include_usage)
vim.env.COPILOT_GITHUB_TOKEN = 'test-token'
for _, endpoint in ipairs({ '/chat/completions', '/responses' }) do
  package.loaded['codeit.providers'] = nil
  local provider = require('codeit.providers')
  done = 0
  vim.system = function(args, options, callback)
    local url = args[#args]
    local response
    if url:find('/models', 1, true) then
      response = vim.json.encode({ data = { { id = 'test', supported_endpoints = { endpoint } } } }) .. '\n200'
    elseif url:find('/token', 1, true) then
      response = vim.json.encode({ token = 'bearer', expires_at = os.time() + 300 }) .. '\n200'
    else
      assert(url:sub(-#endpoint) == endpoint)
      local request = vim.json.decode(options.stdin)
      assert(request.stream)
      response = header .. (endpoint == '/responses'
        and event({ type = 'response.output_text.delta', delta = 'Answer' })
          .. event({ type = 'response.completed', response = final })
        or chat({ content = 'Answer' }) .. chat({}, 'stop') .. event('[DONE]')) .. '\n200'
      options.stdout(nil, response)
      response = nil
    end
    vim.schedule(function() callback({ code = 0, stdout = response }) end)
  end
  provider.chat({ provider = 'copilot', model = 'test' }, {}, {}, function(value, failure)
    assert(not failure and value.content == 'Answer')
    done = done + 1
  end, function(text) assert(text == 'Answer') end)
  assert(vim.wait(2000, function() return done > 0 end))
  assert(done == 1)
end
-- Cancelling an active chat kills its curl process and ignores queued output/results.
local active, killed, finished, stdout = true, false, nil, nil
local completions, cancelled_previews = 0, 0
vim.system = function(_, options, callback)
  finished, stdout = callback, options.stdout
  return { kill = function(_, signal) assert(signal == 9); killed = true end }
end
require('codeit.providers').chat({ provider = 'openrouter', model = 'test' }, {}, {},
  function() completions = completions + 1 end,
  function() cancelled_previews = cancelled_previews + 1 end,
  function() return active end)
active = false
assert(vim.wait(1000, function() return killed end), 'cancelled requests must terminate curl')
stdout(nil, header .. chat({ content = 'Stale' }) .. chat({}, 'stop') .. event('[DONE]'))
finished({ code = 0 })
vim.wait(100, function() return false end)
assert(completions == 0 and cancelled_previews == 0)
vim.system, vim.defer_fn = system, defer
print('codeit streaming tests passed')
