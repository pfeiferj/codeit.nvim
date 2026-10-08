vim.opt.runtimepath:prepend(vim.fn.getcwd())
local system = vim.system
local openrouter = vim.env.OPENROUTER_API_KEY
local gh = vim.env.GH_TOKEN
vim.env.OPENROUTER_API_KEY = 'test-openrouter-key'
vim.env.GH_TOKEN = 'test-github-key'
local calls = {}
local http_response = '{"choices":[{"message":{"role":"assistant","content":"ok"}}]}\n200'
vim.system = function(args, options, callback)
  table.insert(calls, { args = args, options = options })
  local result
  if vim.tbl_contains(args, 'https://api.github.com/copilot_internal/v2/token') then
    result = { code = 0, stdout = vim.json.encode({ token = 'copilot-key', expires_at = os.time() + 300 }) }
  else
    result = { code = 0, stdout = http_response }
  end
  vim.schedule(function() callback(result) end)
end
local providers = require('codeit.providers')
local function wait_for_response(config, specs)
  local answer, err
  providers.chat(config, { { role = 'user', content = 'hello' } }, specs or {}, function(message, failure)
    answer, err = message, failure
  end)
  assert(vim.wait(2000, function() return answer ~= nil or err ~= nil end), 'timed out')
  assert(not err, tostring(err))
  assert(answer.content == 'ok')
end
wait_for_response({ provider = 'openrouter', model = 'openai/gpt-4o-mini' }, require('codeit.tools').specs)
assert(vim.tbl_contains(calls[1].args, 'https://openrouter.ai/api/v1/chat/completions'))
local payload = vim.json.decode(calls[1].options.stdin)
assert(payload.model == 'openai/gpt-4o-mini')
assert(payload.tools[1]['function'].parameters.properties ~= vim.NIL)
assert(calls[1].options.stdin:find('"properties":{}', 1, true), 'empty tool properties must encode as {}')
wait_for_response({ provider = 'copilot', model = 'gpt-4o' })
assert(vim.tbl_contains(calls[3].args, 'https://api.githubcopilot.com/chat/completions'))
http_response = '{"error":{"message":"Invalid tool schema"}}\n400'
local failure
providers.chat({ provider = 'openrouter', model = 'openai/gpt-4o-mini' }, {}, require('codeit.tools').specs,
  function(_, err) failure = err end)
assert(vim.wait(2000, function() return failure ~= nil end), 'timed out waiting for HTTP error')
assert(failure == 'HTTP 400: Invalid tool schema', failure)
vim.system = system
vim.env.OPENROUTER_API_KEY = openrouter
vim.env.GH_TOKEN = gh
print('codeit provider tests passed')
