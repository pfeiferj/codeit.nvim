vim.opt.runtimepath:prepend(vim.fn.getcwd())
local system = vim.system
local copilot = vim.env.COPILOT_GITHUB_TOKEN
vim.env.COPILOT_GITHUB_TOKEN = nil
local openrouter = vim.env.OPENROUTER_API_KEY
local gh = vim.env.GH_TOKEN
vim.env.OPENROUTER_API_KEY = 'test-openrouter-key'
vim.env.GH_TOKEN = 'test-github-key'
local calls = {}
local catalog_response = '{"data":[{"id":"gpt-4o"}]}\n200'
local http_response = '{"choices":[{"message":{"role":"assistant","content":"ok"}}],"usage":{"cost":0.00042,"prompt_tokens":100,"completion_tokens":25,"total_tokens":125,"prompt_tokens_details":{"cached_tokens":60}},"copilot_usage":{"total_nano_aiu":360000}}\n200'
vim.system = function(args, options, callback)
  table.insert(calls, { args = args, options = options })
  local result
  if vim.tbl_contains(args, 'https://api.github.com/copilot_internal/v2/token') then
    result = { code = 0, stdout = vim.json.encode({ token = 'copilot-key', expires_at = os.time() + 300 }) .. '\n200' }
  elseif args[#args]:match('/models$') then
    result = { code = 0, stdout = catalog_response }
  else
    result = { code = 0, stdout = http_response }
  end
  vim.schedule(function() callback(result) end)
end
local providers = require('codeit.providers')
local function wait_for_response(config, specs)
  local answer, err, billing
  providers.chat(config, {
    { role = 'user', content = 'hello' },
    { role = 'assistant', content = 'prior reply', _copilot_reasoning = {
      { type = 'reasoning', encrypted_content = 'private-replay-data' },
    }, reasoning_details = { { type = 'reasoning.encrypted', data = 'chat-replay-data' } } },
  }, specs or {}, function(message, failure, usage)
    answer, err, billing = message, failure, usage
  end)
  assert(vim.wait(2000, function() return answer ~= nil or err ~= nil end), 'timed out')
  assert(not err, tostring(err))
  assert(answer.content == 'ok')
  assert(billing.cached_tokens == 60)
  assert(vim.json.decode(calls[#calls].options.stdin).messages[2]._copilot_reasoning == nil,
    'Responses replay metadata must not leak to Copilot or OpenRouter chat completions')
  assert(vim.json.decode(calls[#calls].options.stdin).messages[2].reasoning_details[1].data == 'chat-replay-data',
    'chat-completions reasoning details must be replayed unchanged')
  if config.provider == 'openrouter' then
    assert(billing.cost == 0.00042)
    assert(billing.prompt_tokens == 100 and billing.completion_tokens == 25 and billing.total_tokens == 125)
  else
    assert(billing.cost == 360000 / 100000000000, 'Copilot cost must convert nano-AIU to USD, not use usage.cost')
    assert(billing.prompt_tokens == 100 and billing.completion_tokens == 25 and billing.total_tokens == 125)
    assert(vim.tbl_contains(calls[#calls].args, 'X-GitHub-Api-Version: 2026-08-01'))
  end
end
wait_for_response({ provider = 'openrouter', model = 'openai/gpt-4o-mini' }, require('codeit.tools').specs)
assert(vim.tbl_contains(calls[1].args, 'https://openrouter.ai/api/v1/chat/completions'))
local payload = vim.json.decode(calls[1].options.stdin)
assert(payload.model == 'openai/gpt-4o-mini')
assert(payload.usage.include == true)
wait_for_response({ provider = 'openrouter', model = 'test', max_output_tokens = 256 })
assert(vim.json.decode(calls[#calls].options.stdin).max_tokens == 256)
table.remove(calls) -- Preserve the catalog/auth call-number checks below.
assert(payload.tools[1]['function'].parameters.properties ~= vim.NIL)
assert(calls[1].options.stdin:find('"properties":{}', 1, true), 'empty tool properties must encode as {}')
wait_for_response({ provider = 'copilot', model = 'gpt-4o' })
assert(vim.tbl_contains(calls[3].args, 'https://api.githubcopilot.com/models'))
assert(vim.tbl_contains(calls[4].args, 'https://api.githubcopilot.com/chat/completions'))
assert(vim.json.decode(calls[4].options.stdin).usage == nil)
local business_options = { api_host = 'api.business.githubcopilot.com' }
wait_for_response({ provider = 'copilot', model = 'gpt-4o', options = business_options })
assert(vim.tbl_contains(calls[#calls].args, 'https://api.business.githubcopilot.com/chat/completions'))
assert(vim.json.decode(calls[#calls].options.stdin).api_host == nil, 'host is routing config, not a request body field')
wait_for_response({ provider = 'copilot', model = 'gpt-4o', options = { api_host = '' } })
assert(vim.tbl_contains(calls[#calls].args, 'https://api.githubcopilot.com/chat/completions'))
wait_for_response({ provider = 'copilot', model = 'gpt-4o', options = { api_host = 'api.githubcopilot.com' } })
assert(vim.tbl_contains(calls[#calls].args, 'https://api.githubcopilot.com/chat/completions'))
wait_for_response({ provider = 'openrouter', model = 'test-model', options = {
  preferred_provider = 'anthropic', service_tier = 'priority', effort = 'high',
} })
payload = vim.json.decode(calls[#calls].options.stdin)
assert(vim.deep_equal(payload.provider.order, { 'anthropic' }))
assert(payload.service_tier == 'priority' and payload.reasoning.effort == 'high')
wait_for_response({ provider = 'openrouter', model = 'test-model', options = {
  preferred_provider = '', service_tier = '', effort = '', routing_mode = '',
} })
payload = vim.json.decode(calls[#calls].options.stdin)
assert(payload.provider == nil and payload.service_tier == nil and payload.reasoning == nil)
for _, mode in ipairs({ 'auto', 'price', 'latency', 'throughput' }) do
  wait_for_response({ provider = 'openrouter', model = 'test-model', options = {
    routing_mode = mode, preferred_provider = 'anthropic', service_tier = 'priority', effort = 'high',
  } })
  payload = vim.json.decode(calls[#calls].options.stdin)
  if mode == 'auto' then
    assert(payload.provider == nil, 'automatic routing must not force a provider')
  else
    assert(vim.deep_equal(payload.provider, { sort = mode }), 'routing mode sets sort without provider order')
  end
  assert(payload.service_tier == 'priority', 'routing modes must preserve the requested service tier')
  assert(payload.reasoning.effort == 'high')
  assert(payload.routing_mode == nil, 'routing mode is local configuration, not an API field')
  for _, options in ipairs({ { routing_mode = mode }, { routing_mode = mode, service_tier = '' } }) do
    wait_for_response({ provider = 'openrouter', model = 'test-model', options = options })
    payload = vim.json.decode(calls[#calls].options.stdin)
    assert(payload.service_tier == nil, 'unset or cleared service tiers must be omitted with routing modes')
  end
end
wait_for_response({ provider = 'openrouter', model = 'test-model', options = {
  routing_mode = '', preferred_provider = 'anthropic', service_tier = 'priority',
} })
payload = vim.json.decode(calls[#calls].options.stdin)
assert(vim.deep_equal(payload.provider.order, { 'anthropic' }) and payload.service_tier == 'priority',
  'clearing the routing mode restores preferred-provider routing without changing the tier')
wait_for_response({ provider = 'copilot', model = 'test-model', options = {
  preferred_provider = 'anthropic', service_tier = 'priority', effort = 'high', routing_mode = 'price',
} })
payload = vim.json.decode(calls[#calls].options.stdin)
assert(payload.provider == nil and payload.service_tier == nil and payload.reasoning == nil,
  'OpenRouter options must not leak to Copilot')

catalog_response = vim.json.encode({ data = { { id = 'z-model', name = 'Last' }, { id = 'a-model', name = 'First' } } }) .. '\n200'
for _, backend in ipairs({ 'openrouter', 'copilot' }) do
  local models, catalog_error
  providers.models(backend, function(result, err) models, catalog_error = result, err end)
  assert(vim.wait(2000, function() return models ~= nil or catalog_error ~= nil end))
  assert(not catalog_error and models[1].id == 'a-model' and models[2].id == 'z-model')
  local url = backend == 'openrouter' and 'https://openrouter.ai/api/v1/models' or 'https://api.githubcopilot.com/models'
  assert(vim.tbl_contains(calls[#calls].args, url))
  assert(vim.tbl_contains(calls[#calls].args, 'X-GitHub-Api-Version: 2026-08-01') == (backend == 'copilot'),
    'the pricing-enabled API version must be sent only for Copilot catalogs')
end
local business_models, business_error
providers.models('copilot', function(result, err) business_models, business_error = result, err end, business_options)
assert(vim.wait(2000, function() return business_models ~= nil or business_error ~= nil end))
assert(not business_error and #business_models == 2)
assert(vim.tbl_contains(calls[#calls].args, 'https://api.business.githubcopilot.com/models'))
assert(vim.tbl_contains(calls[#calls].args, 'X-GitHub-Api-Version: 2026-08-01'),
  'custom Copilot hosts must also use the pricing-enabled API version')
assert(vim.tbl_contains(calls[2].args, 'https://api.github.com/copilot_internal/v2/token'),
  'token exchange must stay on GitHub, regardless of the API host')

-- Reject non-Copilot destinations before any network request (including token exchange).
for _, host in ipairs({ 'attacker.example', 'http://api.business.githubcopilot.com',
  'api.business.githubcopilot.com/path', false }) do
  local before_calls = #calls
  local invalid_error
  providers.models('copilot', function(_, err) invalid_error = err end, { api_host = host })
  assert(invalid_error and invalid_error:find('Invalid Copilot API host', 1, true))
  invalid_error = nil
  providers.chat({ provider = 'copilot', model = 'gpt-4o', options = { api_host = host } }, {}, {},
    function(_, err) invalid_error = err end)
  assert(invalid_error and invalid_error:find('Invalid Copilot API host', 1, true))
  invalid_error = nil
  providers.context_limit({ provider = 'copilot', model = 'gpt-4o', options = { api_host = host } },
    function(_, err) invalid_error = err end)
  assert(invalid_error and invalid_error:find('Invalid Copilot API host', 1, true))
  assert(#calls == before_calls, 'invalid host must not send credentials or API requests')
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

for _, backend in ipairs({ 'openrouter', 'copilot' }) do
  for _, content in ipairs({ vim.NIL, '', {} }) do
    http_response = vim.json.encode({ choices = { { message = {
      role = 'assistant', content = content, refusal = 'Cannot help with that',
    } } } }) .. '\n200'
    local answer, failure
    providers.chat({ provider = backend, model = 'test' }, {}, {}, function(message, err)
      answer, failure = message, err
    end)
    assert(vim.wait(2000, function() return answer ~= nil or failure ~= nil end))
    assert(not failure and answer.content == 'Cannot help with that', 'refusal-only answers must be visible')
  end
end
http_response = vim.json.encode({ choices = { { message = {
  role = 'assistant', content = 'Existing answer', refusal = 'Refusal',
} } } }) .. '\n200'
local text_answer
providers.chat({ provider = 'openrouter', model = 'test' }, {}, {}, function(message, err)
  assert(not err); text_answer = message
end)
assert(vim.wait(2000, function() return text_answer ~= nil end))
assert(text_answer.content == 'Existing answer', 'refusal normalization must not overwrite existing text')
for _, value in ipairs({ vim.NIL, { choices = vim.NIL }, { choices = { vim.NIL } },
  { choices = { { message = vim.NIL } } } }) do
  http_response = vim.json.encode(value) .. '\n200'
  local failure
  providers.chat({ provider = 'openrouter', model = 'test' }, {}, {}, function(message, err)
    assert(message == nil); failure = err
  end)
  assert(vim.wait(2000, function() return failure ~= nil end))
  assert(failure == 'Response has no assistant message', tostring(failure))
end

http_response = vim.json.encode({ choices = { { finish_reason = 'length', message = { content = 'partial' } } },
  usage = { cost = 0.1, prompt_tokens = 100, completion_tokens = 25 },
  copilot_usage = { total_nano_aiu = 360000 },
}) .. '\n200'
for _, backend in ipairs({ 'openrouter', 'copilot' }) do
  local cap_failure, cap_usage
  providers.chat({ provider = backend, model = 'test', max_output_tokens = 256 },
    { { role = 'user', content = 'summarize' } }, {}, function(message, err, usage)
      assert(message == nil); cap_failure, cap_usage = err, usage
    end)
  assert(vim.wait(2000, function() return cap_failure ~= nil end))
  assert(cap_failure:find('token cap', 1, true))
  assert(cap_usage.cost == (backend == 'openrouter' and 0.1 or 360000 / 100000000000))
  assert(cap_usage.prompt_tokens == 100 and cap_usage.completion_tokens == 25)

  local answer
  providers.chat({ provider = backend, model = 'test', max_output_tokens = false }, {}, {}, function(message, err)
    assert(not err); answer = message
  end)
  assert(vim.wait(2000, function() return answer ~= nil end))
  assert(answer.content == 'partial', 'uncapped chat must not reject length-limited results')
  local request = vim.json.decode(calls[#calls].options.stdin)
  assert(request.max_tokens == nil and request.max_completion_tokens == nil)
end

local unknown_calls = #calls
local unknown_error
providers.models('unknown', function(_, err) unknown_error = err end)
assert(unknown_error == 'Unknown provider: unknown')
unknown_error = nil
providers.chat({ provider = 'unknown', model = 'test' }, {}, {}, function(_, err) unknown_error = err end)
assert(unknown_error == 'Unknown provider: unknown' and #calls == unknown_calls)

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
catalog_response = '{"error":{"message":"Metadata unavailable","debug":"metadata details"}}\n503'
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
