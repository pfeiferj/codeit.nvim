vim.opt.runtimepath:prepend(vim.fn.getcwd())
local requests = {}
package.loaded['codeit.providers.http'] = {
  post = function(url, headers, body, callback, streaming, active)
    requests[#requests + 1] = { url = url, headers = headers, body = body, callback = callback, active = active }
    assert(streaming == nil)
  end,
}
local provider = require('codeit.providers.decisions')
local questions = { risk = { type = 'score', instructions = 'Rate risk', criteria = { 'Low', 'High' } } }
local state = { tool = 'inspect', arguments = {} }
local answer, failure, usage
local function done(value, err, billing) answer, failure, usage = value, err, billing end
local function response(index)
  requests[index].callback({ answers = { risk = { type = 'score', score = 0.5 } },
    usage = { input_tokens = 123, output_tokens = 7, cost = 0.01 } })
end
vim.env.TYPESAFE_API_KEY = nil
provider.evaluate({ provider = 'typesafe', model = 'jev-latest' }, state, questions, done)
assert(failure:find('TYPESAFE_API_KEY', 1, true) and #requests == 0)
vim.env.TYPESAFE_API_KEY = 'test-typesafe-key'
provider.evaluate({ provider = 'typesafe', model = 'jev-latest' }, state, questions, done)
assert(requests[1].url == 'https://api.typesafe.ai/v1/systemone')
assert(vim.tbl_contains(requests[1].headers, 'Authorization: Bearer test-typesafe-key'))
assert(vim.deep_equal(requests[1].body, { model = 'jev-latest', state = state, questions = questions }))
response(1)
assert(answer.risk.score == 0.5 and failure == nil)
assert(vim.deep_equal(usage, { prompt_tokens = 123, completion_tokens = 7, cost = 0.01 }))

provider.evaluate({ provider = 'decisions', model = 'local', options = { base_url = 'http://localhost:8000/v1/' } }, state, questions, done)
assert(requests[2].url == 'http://localhost:8000/v1/systemone')
assert(vim.deep_equal(requests[2].headers, { 'Content-Type: application/json' }))
requests[2].callback({ answers = {}, usage = { input_tokens = 2, output_tokens = 1 } })
assert(usage.cost == nil and usage.prompt_tokens == 2)
vim.env.LOCAL_DECISIONS_KEY = 'local-test-key'
provider.evaluate({ provider = 'decisions', model = 'local', options = {
  base_url = 'http://localhost:8000/v1', api_key_env = 'LOCAL_DECISIONS_KEY',
} }, state, questions, done)
assert(vim.tbl_contains(requests[3].headers, 'Authorization: Bearer local-test-key'))
requests[3].callback(nil, 'HTTP 529: overloaded')
assert(answer == nil and failure == 'HTTP 529: overloaded')

vim.env.OPENROUTER_API_KEY = 'test-openrouter-key'
provider.evaluate({ provider = 'openrouter', model = 'typesafe/jev-1.13', options = {
  routing_mode = 'latency', allow_fallbacks = false, effort = 'high', response_healing = true,
} }, state, questions, done)
assert(requests[4].url == 'https://openrouter.ai/api/alpha/decisions')
assert(vim.tbl_contains(requests[4].headers, 'Authorization: Bearer test-openrouter-key'))
assert(vim.deep_equal(requests[4].body.provider, { sort = 'latency', allow_fallbacks = false }))
assert(requests[4].body.messages == nil and requests[4].body.reasoning == nil and requests[4].body.plugins == nil)
requests[4].callback('malformed')
assert(answer == nil and failure == 'Invalid decisions response')

for _, url in ipairs({ 'file:///tmp/api', 'http://host/?key=secret', 'https://user@host', 'http://host/\nheader' }) do
  assert(not provider.url('decisions', { base_url = url }))
end
assert(not provider.url('decisions', {}))
provider.evaluate({ provider = 'decisions', options = { base_url = 'http://localhost', api_key_env = 'BAD-NAME' } }, state, questions, done)
assert(failure == 'Invalid API key environment variable' and #requests == 4)
provider.evaluate({ provider = 'copilot' }, state, questions, done)
assert(failure:find('require typesafe', 1, true) and #requests == 4)
provider.evaluate({ provider = 'typesafe' }, state, questions, done, function() return false end)
assert(#requests == 4)
local live, callbacks = true, 0
provider.evaluate({ provider = 'typesafe', model = 'jev-latest' }, state, questions, function() callbacks = callbacks + 1 end,
  function() return live end)
live = false
response(5)
assert(callbacks == 0)
print('decisions provider tests passed')
