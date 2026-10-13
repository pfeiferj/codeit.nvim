vim.opt.runtimepath:prepend(vim.fn.getcwd())
local stream = require('codeit.providers.protocols.stream')
local function event(value)
  return 'data: ' .. (type(value) == 'string' and value or vim.json.encode(value)) .. '\r\n\r\n'
end
local header = 'HTTP/1.1 200 Connection established\r\n\r\nHTTP/2 200\r\nContent-Type: text/event-stream\r\n\r\n'
local function chat(delta, finish)
  return event({ choices = { { index = 0, delta = delta, finish_reason = finish } } })
end
local activity = 0
local activity_parser = stream.new(false, function() error('non-text events must not produce previews') end,
  function() activity = activity + 1 end)
activity_parser.push(header .. ': heartbeat\r\n\r\n')
assert(activity == 0, 'headers and keepalive comments are not response data')
activity_parser.push(chat({ reasoning_details = { { index = 0, type = 'reasoning.text', text = 'Thinking' } } }))
activity_parser.push(chat({ tool_calls = { { index = 0, id = 'call',
  ['function'] = { name = 'read_file', arguments = '{}' } } } }))
assert(activity == 2, 'reasoning and tool-call data should signal streaming activity')
activity = 0
activity_parser = stream.new(true, function() error('non-text events must not produce previews') end,
  function() activity = activity + 1 end)
activity_parser.push(header .. event({ type = 'response.reasoning_summary_text.delta', delta = 'Thinking' }))
activity_parser.push(event({ type = 'response.function_call_arguments.delta', delta = '{}' }))
assert(activity == 2, 'Responses reasoning and tool-call data should signal streaming activity')
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
local normalized = require('codeit.providers.protocols.responses').message(result)
assert(normalized.tool_calls[1].id == 'call' and normalized._copilot_reasoning[1].encrypted_content == 'encrypted')
parser = stream.new(true, function() end)
parser.push(header .. event({ type = 'response.output_text.delta', delta = 'partial' }) .. event('[DONE]'))
assert(select(2, parser.finish()), 'Responses requires its terminal response, not just DONE')

local headerless = 'HTTP/2 200\r\n\r\n'
for _, response_header in ipairs({
  headerless,
  'HTTP/2 200\r\nContent-Type: application/json\r\n\r\n',
  'HTTP/1.1 200 Connection established\r\n\r\nHTTP/1.1 100 Continue\r\n\r\n' .. headerless,
}) do
  for _, responses in ipairs({ false, true }) do
    local preview
    parser = stream.new(responses, function(text) preview = text end)
    local frames = responses
      and event({ type = 'response.output_text.delta', delta = 'Answer' })
        .. event({ type = 'response.completed', response = final })
      or 'data: {"choices":\r\ndata: [{"index":0,"delta":{"content":"Answer"},"finish_reason":"stop"}]}\r\n\r\n'
        .. event('[DONE]')
    local body = response_header .. ': heartbeat\r\n\r\nid: 1\r\nretry: 1000\r\n\r\nevent: message\r\n'
      .. frames .. '\n200'
    for i = 1, #body do parser.push(body:sub(i, i)) end
    result, err, streamed = parser.finish()
    assert(streamed and not err and preview == 'Answer', err)
    assert(responses and vim.deep_equal(result, final)
      or not responses and result.choices[1].message.content == 'Answer')
  end
end
for _, responses in ipairs({ false, true }) do
  for _, tail in ipairs({
    responses and event({ type = 'response.output_text.delta', delta = 'partial' }) or chat({ content = 'partial' }),
    'data: {invalid}\r\n\r\n',
  }) do
    parser = stream.new(responses)
    parser.push(headerless .. tail)
    result, err, streamed = parser.finish()
    assert(streamed and not result and err, 'headerless SSE must retain streaming errors')
  end
end
for _, body in ipairs({
  headerless .. '{\n"data": "data: not an event",\n\n"choices": []\n}\n200',
  headerless .. 'not an SSE frame\n\ndata: {invalid}\n\n\n200',
  headerless .. ': heartbeat\r\n\r\n\n200',
  'HTTP/2 400\r\n\r\n' .. chat({ content = 'error' }) .. event('[DONE]') .. '\n400',
  'HTTP/2 429\r\nContent-Type: text/event-stream\r\n\r\n' .. event({ error = 'rate limited' }) .. '\n429',
}) do
  parser = stream.new(false, function() error('non-streaming responses must not produce previews') end)
  parser.push(body)
  result, err, streamed = parser.finish()
  assert(not streamed and not result and not err, 'JSON and HTTP errors must remain on their existing paths')
end

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
activity = 0
require('codeit.providers').chat({ provider = 'openrouter', model = 'test' }, {}, {}, function(value, failure, usage)
  assert(not failure and value.content == 'Hello' and usage.total_tokens == 9)
  done = done + 1
end, function(text) live[#live + 1] = text end, nil, function() activity = activity + 1 end)
assert(vim.wait(2000, function() return done > 0 end))
assert(activity > 0, 'provider adapters should forward streaming activity')
assert(done == 1 and attempts == 2 and waits[1] == 0 and body.stream and body.stream_options.include_usage)
-- Completion may be queued before stdout's scheduled parser work, even though all bytes are received.
for _, response_header in ipairs({ header, headerless }) do
  for _, responses in ipairs({ false, true }) do
    for _, partial in ipairs({ false, true }) do
      local previews, completions, settled, completion_previews = {}, 0, false, nil
      local response, failure
      local prefix = response_header .. (responses
        and event({ type = 'response.output_text.delta', delta = 'Ans' }) or chat({ content = 'Ans' }))
      local tail = (responses
        and event({ type = 'response.output_text.delta', delta = 'wer' })
          .. event({ type = 'response.completed', response = final })
        or chat({ content = 'wer' }) .. chat({}, 'stop')
          .. event({ choices = {}, usage = { total_tokens = 9 } }) .. event('[DONE]')) .. '\n200'
      vim.system = function(_, options, callback)
        local function complete()
          callback({ code = 0 })
          if not partial then options.stdout(nil, prefix) end
          options.stdout(nil, tail)
        end
        if partial then
          options.stdout(nil, prefix)
          vim.schedule(complete)
        else
          complete()
        end
      end
      require('codeit.providers.http').post('https://example.test/chat', {}, {}, function(value, err)
        response, failure = value, err
        completions = completions + 1
        completion_previews = #previews
        vim.schedule(function() settled = true end)
      end, { responses = responses, on_text = function(text) previews[#previews + 1] = text end })
      assert(vim.wait(2000, function() return settled end), 'out-of-order completion timed out')
      assert(not failure, failure)
      assert(completions == 1 and completion_previews == 2 and #previews == 2,
        'chunks must be parsed exactly once, before completion')
      assert(previews[1] == 'Ans' and previews[2] == 'Answer')
      if responses then
        assert(vim.deep_equal(response, final))
      else
        assert(response.choices[1].message.content == 'Answer' and response.usage.total_tokens == 9)
      end
    end
  end
end
vim.env.COPILOT_GITHUB_TOKEN = 'test-token'
for _, mode in ipairs({ 'live', 'buffered', 'live_headerless', 'buffered_headerless', 'incomplete', 'malformed' }) do
  local is_live = mode:find('live', 1, true) == 1
  for _, endpoint in ipairs({ '/chat/completions', '/responses' }) do
    package.loaded['codeit.providers'] = nil
    package.loaded['codeit.providers.copilot'] = nil
    package.loaded['codeit.providers.copilot.auth'] = nil
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
        assert((request.stream == true) == is_live)
        assert((options.stdout ~= nil) == is_live)
        response = header .. (endpoint == '/responses'
          and event({ type = 'response.output_text.delta', delta = 'Answer' })
            .. event({ type = 'response.completed', response = final })
          or chat({ content = 'Answer' }) .. chat({}, 'stop') .. event('[DONE]')) .. '\n200'
        if mode == 'incomplete' then
          response = header .. (endpoint == '/responses'
            and event({ type = 'response.output_text.delta', delta = 'Answer' })
            or chat({ content = 'Answer' })) .. '\n200'
        elseif mode == 'malformed' then
          response = header .. 'data: {invalid}\r\n\r\n\n200'
        end
        if mode:find('headerless', 1, true) then
          response = response:gsub('Content%-Type: text/event%-stream\r\n', '')
        end
        if options.stdout then
          options.stdout(nil, response)
          response = nil
        end
      end
      vim.schedule(function() callback({ code = 0, stdout = response }) end)
    end
    provider.chat({ provider = 'copilot', model = 'test' }, {}, {}, function(value, failure)
      if mode == 'incomplete' or mode == 'malformed' then
        assert(not value and failure, 'invalid SSE must not return a partial message')
        local expected = mode == 'incomplete' and 'Streaming response ended before completion'
          or 'Invalid streaming response:'
        assert(failure:find(expected, 1, true), failure)
      else
        assert(not failure and value.content == 'Answer', failure)
      end
      done = done + 1
    end, is_live and function(text) assert(text == 'Answer') end or nil)
    assert(vim.wait(2000, function() return done > 0 end))
    assert(done == 1)
  end
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
