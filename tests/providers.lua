vim.opt.runtimepath:prepend(vim.fn.getcwd())
local system = vim.system
local copilot = vim.env.COPILOT_GITHUB_TOKEN
vim.env.COPILOT_GITHUB_TOKEN = nil
local openrouter = vim.env.OPENROUTER_API_KEY
local gh = vim.env.GH_TOKEN
vim.env.OPENROUTER_API_KEY = 'test-openrouter-key'
vim.env.GH_TOKEN = 'test-github-key'
local calls = {}
local http_response = '{"choices":[{"message":{"role":"assistant","content":"ok"}}],"usage":{"cost":0.00042,"prompt_tokens":100,"completion_tokens":25,"total_tokens":125}}\n200'
vim.system = function(args, options, callback)
  table.insert(calls, { args = args, options = options })
  local result
  if vim.tbl_contains(args, 'https://api.github.com/copilot_internal/v2/token') then
    result = { code = 0, stdout = vim.json.encode({ token = 'copilot-key', expires_at = os.time() + 300 }) .. '\n200' }
  else
    result = { code = 0, stdout = http_response }
  end
  vim.schedule(function() callback(result) end)
end
local providers = require('codeit.providers')
local function wait_for_response(config, specs)
  local answer, err, billing
  providers.chat(config, { { role = 'user', content = 'hello' } }, specs or {}, function(message, failure, usage)
    answer, err, billing = message, failure, usage
  end)
  assert(vim.wait(2000, function() return answer ~= nil or err ~= nil end), 'timed out')
  assert(not err, tostring(err))
  assert(answer.content == 'ok')
  if config.provider == 'openrouter' then
    assert(billing.cost == 0.00042)
    assert(billing.prompt_tokens == 100 and billing.completion_tokens == 25 and billing.total_tokens == 125)
  else
    assert(billing == nil)
  end
end
wait_for_response({ provider = 'openrouter', model = 'openai/gpt-4o-mini' }, require('codeit.tools').specs)
assert(vim.tbl_contains(calls[1].args, 'https://openrouter.ai/api/v1/chat/completions'))
local payload = vim.json.decode(calls[1].options.stdin)
assert(payload.model == 'openai/gpt-4o-mini')
assert(payload.usage.include == true)
assert(payload.tools[1]['function'].parameters.properties ~= vim.NIL)
assert(calls[1].options.stdin:find('"properties":{}', 1, true), 'empty tool properties must encode as {}')
wait_for_response({ provider = 'copilot', model = 'gpt-4o' })
assert(vim.tbl_contains(calls[3].args, 'https://api.githubcopilot.com/chat/completions'))
assert(vim.json.decode(calls[3].options.stdin).usage == nil)
wait_for_response({ provider = 'openrouter', model = 'test-model', options = {
  preferred_provider = 'anthropic', service_tier = 'priority', effort = 'high',
} })
payload = vim.json.decode(calls[#calls].options.stdin)
assert(vim.deep_equal(payload.provider.order, { 'anthropic' }))
assert(payload.service_tier == 'priority' and payload.reasoning.effort == 'high')
wait_for_response({ provider = 'openrouter', model = 'test-model', options = {
  preferred_provider = '', service_tier = '', effort = '',
} })
payload = vim.json.decode(calls[#calls].options.stdin)
assert(payload.provider == nil and payload.service_tier == nil and payload.reasoning == nil)
wait_for_response({ provider = 'copilot', model = 'test-model', options = {
  preferred_provider = 'anthropic', service_tier = 'priority', effort = 'high',
} })
payload = vim.json.decode(calls[#calls].options.stdin)
assert(payload.provider == nil and payload.service_tier == nil and payload.reasoning == nil,
  'OpenRouter options must not leak to Copilot')

http_response = vim.json.encode({ data = { { id = 'z-model', name = 'Last' }, { id = 'a-model', name = 'First' } } }) .. '\n200'
for _, backend in ipairs({ 'openrouter', 'copilot' }) do
  local models, catalog_error
  providers.models(backend, function(result, err) models, catalog_error = result, err end)
  assert(vim.wait(2000, function() return models ~= nil or catalog_error ~= nil end))
  assert(not catalog_error and models[1].id == 'a-model' and models[2].id == 'z-model')
  local url = backend == 'openrouter' and 'https://openrouter.ai/api/v1/models' or 'https://api.githubcopilot.com/models'
  assert(vim.tbl_contains(calls[#calls].args, url))
end
local function endpoints_for(model, response)
  http_response = response
  local endpoints, endpoint_error
  providers.endpoints(model, function(result, err) endpoints, endpoint_error = result, err end)
  assert(vim.wait(2000, function() return endpoints ~= nil or endpoint_error ~= nil end))
  return endpoints, endpoint_error
end
local endpoints = endpoints_for('openai/test:nitro', vim.json.encode({ data = { endpoints = {
  { tag = 'z-provider', pricing = { prompt = '0.000003', completion = '0.000015' }, status = 0 },
  { tag = 'offline', status = -1 },
  { provider_name = 'No routing tag' },
  { tag = 'a-provider/fast', pricing = { prompt = '0', completion = '0' } },
} } }) .. '\n200')
assert(#endpoints == 2 and endpoints[1].tag == 'a-provider/fast' and endpoints[2].tag == 'z-provider')
assert(endpoints[2].pricing.prompt == '0.000003')
assert(vim.tbl_contains(calls[#calls].args, 'https://openrouter.ai/api/v1/models/openai/test/endpoints'))
endpoints_for('openai/test:free', '{"data":{"endpoints":[]}}\n200')
assert(vim.tbl_contains(calls[#calls].args, 'https://openrouter.ai/api/v1/models/openai/test%3Afree/endpoints'))
local _, endpoint_error = endpoints_for('openai/test', '{"data":{}}\n200')
assert(endpoint_error == 'Invalid model endpoint catalog')
_, endpoint_error = endpoints_for('openai/test', '{"error":{"message":"No endpoints"}}\n404')
assert(endpoint_error == 'HTTP 404: No endpoints')
_, endpoint_error = endpoints_for('invalid', '{"data":{"endpoints":[]}}\n200')
assert(endpoint_error:find('author/model', 1, true))

local log_path = vim.fn.stdpath('state') .. '/codeit/provider-errors.log'
local before = vim.fn.filereadable(log_path) == 1 and table.concat(vim.fn.readfile(log_path), '\n') or ''
http_response = '{"error":{"message":"Invalid tool schema","debug":"schema details"}}\n400'
local failure
providers.chat({ provider = 'openrouter', model = 'openai/gpt-4o-mini' }, {}, require('codeit.tools').specs,
  function(_, err) failure = err end)
assert(vim.wait(2000, function() return failure ~= nil end), 'timed out waiting for HTTP error')
assert(failure == 'HTTP 400: Invalid tool schema', failure)
local logged = table.concat(vim.fn.readfile(log_path), '\n')
assert(#logged > #before and logged:find('openrouter/openai/gpt-4o-mini: HTTP 400: Invalid tool schema', #before + 1, true))
assert(logged:find('schema details', #before + 1, true), 'full provider response should be logged')
assert(not logged:find('test-openrouter-key', 1, true), 'do not log authorization tokens')
assert(vim.uv.fs_stat(log_path).mode % 512 == 384, 'new error logs should be private')
http_response = '{"error":{"message":"Metadata unavailable","debug":"metadata details"}}\n503'
local metadata_error
providers.context_limit({ provider = 'openrouter', model = 'test-metadata-error' }, function(_, err)
  metadata_error = err
end)
assert(vim.wait(2000, function() return metadata_error ~= nil end), 'timed out waiting for metadata error')
assert(metadata_error == 'HTTP 503: Metadata unavailable')
assert(table.concat(vim.fn.readfile(log_path), '\n'):find('metadata details', #logged + 1, true),
  'metadata provider failures should also be logged')
vim.system = system
vim.env.COPILOT_GITHUB_TOKEN = copilot
vim.env.OPENROUTER_API_KEY = openrouter
vim.env.GH_TOKEN = gh
print('codeit provider tests passed')
