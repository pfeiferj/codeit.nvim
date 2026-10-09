vim.opt.runtimepath:prepend(vim.fn.getcwd())
local original_system, original_key, original_gh = vim.system, vim.env.OPENROUTER_API_KEY, vim.env.GH_TOKEN
local original_copilot = vim.env.COPILOT_GITHUB_TOKEN
vim.env.COPILOT_GITHUB_TOKEN = nil
vim.env.OPENROUTER_API_KEY = 'test-openrouter-key'
vim.env.GH_TOKEN = 'test-github-key'
local calls = {}
vim.system = function(args, _, callback)
  calls[#calls + 1] = { args = args, callback = callback }
end
local providers = require('codeit.providers')
local function reply(index, data, status)
  calls[index].callback({ code = 0, stdout = vim.json.encode(data) .. '\n' .. (status or '200') })
  -- vim.schedule callbacks run at the next event-loop iteration.
  vim.wait(20)
end
local result, error_message
local openrouter = { provider = 'openrouter', model = 'openai/large' }
providers.context_limit(openrouter, function(value, err) result, error_message = value, err end)
providers.context_limit(openrouter, function(value) assert(value == 1000000) end)
assert(#calls == 1 and vim.tbl_contains(calls[1].args, 'https://openrouter.ai/api/v1/models'))
reply(1, { data = { { id = 'openai/other', context_length = 200 }, { id = 'openai/large', context_length = 1000000 } } })
assert(result == 1000000 and error_message == nil)
providers.context_limit(openrouter, function(value) assert(value == 1000000) end)
assert(#calls == 1, 'model metadata should be cached')
local copilot = { provider = 'copilot', model = 'gpt-4o' }
result = nil
providers.context_limit(copilot, function(value) result = value end)
assert(#calls == 2 and vim.tbl_contains(calls[2].args, 'https://api.github.com/copilot_internal/v2/token'))
reply(2, { token = 'copilot-token', expires_at = os.time() + 3600 })
assert(#calls == 3 and vim.tbl_contains(calls[3].args, 'https://api.githubcopilot.com/models'),
  'calls=' .. #calls .. ' url=' .. tostring(calls[3] and calls[3].args[#calls[3].args]))
reply(3, { data = { { id = 'gpt-4o', capabilities = { limits = { max_prompt_tokens = 90000 } } } } })
assert(result == 90000)
result, error_message = nil, nil
providers.context_limit({ provider = 'openrouter', model = 'unknown' }, function(value, err)
  result, error_message = value, err
end)
reply(4, { data = {} })
assert(result == nil and error_message:find('model not found', 1, true))
providers.context_limit({ provider = 'openrouter', model = 'unknown' }, function(value, err)
  assert(value == nil and err == nil, 'failed lookup should not repeat or warn again')
end)
assert(#calls == 4)

-- A host change must not reuse cached metadata (or cached failures) from the other host.
local business = { provider = 'copilot', model = 'gpt-4o', options = { api_host = 'api.business.githubcopilot.com' } }
result, error_message = nil, nil
providers.context_limit(business, function(value, err) result, error_message = value, err end)
assert(#calls == 5 and vim.tbl_contains(calls[5].args, 'https://api.business.githubcopilot.com/models'))
providers.context_limit(business, function(value) assert(value == 120000) end)
assert(#calls == 5, 'same-host metadata requests should be deduplicated')
reply(5, { data = { { id = 'gpt-4o', capabilities = { limits = { max_prompt_tokens = 120000 } } } } })
assert(result == 120000 and not error_message)
providers.context_limit(copilot, function(value) assert(value == 90000) end)
providers.context_limit(business, function(value) assert(value == 120000) end)
assert(#calls == 5, 'each host should keep its own successful metadata cache')
local blocked = { provider = 'copilot', model = 'blocked-model' }
providers.context_limit(blocked, function(_, err) error_message = err end)
reply(6, { error = { message = 'Blocked standard host' } }, '403')
assert(error_message == 'HTTP 403: Blocked standard host')
blocked.options = business.options
providers.context_limit(blocked, function(value) result = value end)
assert(#calls == 7 and vim.tbl_contains(calls[7].args, 'https://api.business.githubcopilot.com/models'))
reply(7, { data = { { id = 'blocked-model', capabilities = { limits = { max_prompt_tokens = 64000 } } } } })
assert(result == 64000, 'a standard-host failure must not poison business-host metadata')
vim.system, vim.env.OPENROUTER_API_KEY, vim.env.GH_TOKEN = original_system, original_key, original_gh
vim.env.COPILOT_GITHUB_TOKEN = original_copilot
print('codeit model limit tests passed')
