vim.opt.runtimepath:prepend(vim.fn.getcwd())
local system, defer = vim.system, vim.defer_fn
local key = vim.env.OPENROUTER_API_KEY
vim.env.OPENROUTER_API_KEY = 'test-key'
local providers = require('codeit.providers')
local success = '{"choices":[{"message":{"role":"assistant","content":"ok"}}]}\n200'
local function run(responses, metadata)
  local calls, delays, callbacks = {}, {}, 0
  vim.system = function(args, options, callback)
    calls[#calls + 1] = { args = args, options = options }
    local response = responses[math.min(#calls, #responses)]
    vim.schedule(function() callback({ code = 0, stdout = response }) end)
  end
  vim.defer_fn = function(fn, delay)
    delays[#delays + 1] = delay
    vim.schedule(fn)
  end
  local value, failure
  local function done(result, err)
    callbacks = callbacks + 1
    value, failure = result, err
  end
  if metadata then providers.models('openrouter', done)
  else providers.chat({ provider = 'openrouter', model = 'test' }, { { role = 'user', content = 'hi' } }, {}, done) end
  assert(vim.wait(2000, function() return callbacks > 0 end), 'timed out')
  assert(callbacks == 1)
  for _, call in ipairs(calls) do
    assert(vim.tbl_contains(call.args, '--include'))
    assert(vim.deep_equal(call.options, calls[1].options), 'retry must replay the same payload')
  end
  return value, failure, delays, calls
end
local limited = 'HTTP/2 429\r\ncontent-type: text/plain\r\n\r\nToo many requests\n429'
local value, err, delays, calls = run({ limited, success })
assert(value.content == 'ok' and not err)
assert(vim.deep_equal(delays, { 2000 }) and #calls == 2)
value, err, delays, calls = run({ limited })
assert(not value and err:find('HTTP 429: Too many requests', 1, true))
assert(vim.deep_equal(delays, { 2000, 4000, 8000 }) and #calls == 4)
local function with_header(value)
  return 'HTTP/1.1 200 Connection established\r\n\r\nHTTP/1.1 100 Continue\r\n\r\n'
    .. 'HTTP/2 429\r\nrEtRy-AfTeR: ' .. value .. '\r\n\r\n{}\n429'
end
value, err, delays = run({ with_header('7'), success })
assert(value.content == 'ok' and delays[1] == 7000)
value, err, delays = run({ with_header('0'), success })
assert(value.content == 'ok' and delays[1] == 0)
value, err, delays = run({ with_header('invalid'), success })
assert(value.content == 'ok' and delays[1] == 2000)
value, err, delays, calls = run({ with_header('61'), success })
assert(not value and err:find('HTTP 429', 1, true) and #delays == 0 and #calls == 1)
local date = os.date('!%a, %d %b %Y %H:%M:%S GMT', os.time() + 20)
value, err, delays = run({ with_header(date), success })
assert(value.content == 'ok' and delays[1] >= 18000 and delays[1] <= 20000)
value, err, delays, calls = run({ 'HTTP/2 500\r\n\r\nserver error\n500', success })
assert(not value and err:find('HTTP 500: server error', 1, true) and #calls == 1 and #delays == 0)
value, err, delays = run({ limited, 'HTTP/2 200\r\n\r\n{"data":[{"id":"test"}]}\n200' }, true)
assert(value[1].id == 'test' and not err and delays[1] == 2000)
value, err, delays, calls = run({ 'not json\n200', success })
assert(not value and err:find('Invalid JSON response', 1, true) and #calls == 1 and #delays == 0)
vim.system, vim.defer_fn = system, defer
vim.env.OPENROUTER_API_KEY = key
print('codeit rate-limit tests passed')
