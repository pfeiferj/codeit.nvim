vim.opt.runtimepath:prepend(vim.fn.getcwd())
local system, key, custom_key = vim.system, vim.env.OPENAI_API_KEY, vim.env.CODEIT_TEST_API_KEY
vim.env.OPENAI_API_KEY = 'test-openai-key'
vim.env.CODEIT_TEST_API_KEY = 'custom-key'
local calls, status = {}, '200'
local response = { choices = { { message = { role = 'assistant', content = 'ok',
  tool_calls = { { id = 'call', type = 'function', ['function'] = { name = 'read_file', arguments = '{}' } } },
} } }, usage = { prompt_tokens = 10, completion_tokens = 5, total_tokens = 15,
  prompt_tokens_details = { cached_tokens = 4 } } }
local catalog = { data = { { id = 'z' }, { id = 'a', context_length = 32000 } } }
local wire
vim.system = function(args, options, callback)
  calls[#calls + 1] = { args = args, options = options }
  local data = args[#args]:match('/models$') and catalog or response
  vim.schedule(function()
    if wire then options.stdout(nil, wire .. '\n' .. status) end
    callback({ code = 0, stdout = vim.json.encode(data) .. '\n' .. status })
  end)
end
local providers = require('codeit.providers')
local config = { provider = 'openai', model = 'a' }
local function request(on_text, active)
  local done, message, err, billing
  providers.chat(config, { { role = 'user', content = 'hello' } }, {
    { type = 'function', ['function'] = { name = 'read_file', parameters = { type = 'object' } } },
  }, function(result, failure, usage) done, message, err, billing = true, result, failure, usage end, on_text, active)
  if active and not active() then assert(not done); return end
  assert(vim.wait(2000, function() return done end))
  return message, err, billing
end
local message, err, billing = request()
assert(not err and message.content == 'ok' and message.tool_calls[1].id == 'call')
assert(billing.prompt_tokens == 10 and billing.completion_tokens == 5 and billing.cached_tokens == 4)
assert(billing.cost == nil, 'do not invent costs for compatible endpoints')
assert(vim.tbl_contains(calls[#calls].args, 'https://api.openai.com/v1/chat/completions'))
assert(vim.tbl_contains(calls[#calls].args, 'Authorization: Bearer test-openai-key'))
local body = vim.json.decode(calls[#calls].options.stdin)
assert(body.tools[1]['function'].name == 'read_file' and body.tool_choice == 'auto')
assert(body.usage == nil and body.provider == nil, 'omit OpenRouter-specific fields')
config.tool_choice = 'required'
assert(request())
assert(vim.json.decode(calls[#calls].options.stdin).tool_choice == 'required')
config.tool_choice = nil
config.options = { base_url = 'http://localhost:1234/v1///', api_key_env = 'CODEIT_TEST_API_KEY' }
config.max_output_tokens = 64
assert(request())
assert(vim.tbl_contains(calls[#calls].args, 'http://localhost:1234/v1/chat/completions'))
assert(vim.tbl_contains(calls[#calls].args, 'Authorization: Bearer custom-key'))
body = vim.json.decode(calls[#calls].options.stdin)
assert(body.max_tokens == 64 and body.base_url == nil and body.api_key_env == nil)
config.options.api_key_env = ''
assert(request())
for _, arg in ipairs(calls[#calls].args) do assert(not arg:find('Authorization:', 1, true)) end
config.options.api_key_env = 'CODEIT_UNSET_TEST_KEY'
vim.env.CODEIT_UNSET_TEST_KEY = nil
assert(request(), 'local servers may not require authentication')
local count = #calls
request(nil, function() return false end)
assert(#calls == count, 'cancelled requests must not start')
for _, url in ipairs({ false, 'file:///tmp/model', 'https://host/?key=secret', 'https://user:secret@host/v1', 'https://host\n' }) do
  config.options.base_url = url
  message, err = request()
  assert(not message and err:find('Invalid OpenAI-compatible base URL', 1, true))
end
assert(#calls == count, 'invalid destinations must not send requests')
config.options = { base_url = 'http://localhost:1234/v1', api_key_env = '' }
response.choices[1].finish_reason = 'length'
message, err, billing = request()
assert(not message and err:find('token cap', 1, true) and billing.total_tokens == 15)
response.choices[1].finish_reason = nil
status = '401'
response = { error = { message = 'unauthorized' } }
message, err = request()
assert(not message and err == 'HTTP 401: unauthorized')
status = '200'
response = { choices = {} }
message, err = request()
assert(not message and err == 'Response has no assistant message')
wire = 'HTTP/2 200\nContent-Type: text/event-stream\n\ndata: {"choices":[{"index":0,"delta":{"content":"streamed"},"finish_reason":"stop"}]}\n\n'
  .. 'data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}\n\n'
  .. 'data: [DONE]\n\n'
local preview
message, err, billing = request(function(text) preview = text end)
assert(not err and message.content == 'streamed' and preview == 'streamed' and billing.total_tokens == 15)
body = vim.json.decode(calls[#calls].options.stdin)
assert(body.stream and body.stream_options.include_usage)
wire = nil
local done, entries
providers.models('openai', function(result, failure) entries, err, done = result, failure, true end, config.options)
assert(vim.wait(2000, function() return done end))
assert(not err and entries[1].id == 'a' and entries[2].id == 'z')
assert(vim.tbl_contains(calls[#calls].args, 'http://localhost:1234/v1/models'))
for index, url in ipairs({ 'http://localhost:1234/v1', 'http://localhost:5678/v1' }) do
  config.options.base_url = url
  catalog.data[2].context_length = index * 32000
  local limit
  done = false
  providers.context_limit(config, function(value) limit, done = value, true end)
  assert(vim.wait(2000, function() return done end))
  assert(limit == index * 32000, 'context limits must be cached separately per base URL')
end
vim.system, vim.env.OPENAI_API_KEY, vim.env.CODEIT_TEST_API_KEY = system, key, custom_key
print('codeit OpenAI-compatible provider tests passed')
