vim.opt.runtimepath:prepend(vim.fn.getcwd())
local original_system, original_executable, original_time = vim.system, vim.fn.executable, os.time
local env_names = { 'COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN', 'XDG_CONFIG_HOME' }
local original_env = {}
for _, name in ipairs(env_names) do original_env[name] = vim.env[name] end
local temp = vim.fn.tempname()
vim.fn.mkdir(temp .. '/github-copilot', 'p')
vim.env.XDG_CONFIG_HOME = temp
local now = 1000000
os.time = function() return now end
local calls, gh_available, gh_result, exchange_result
vim.fn.executable = function(name)
  if name == 'gh' then return gh_available and 1 or 0 end
  return original_executable(name)
end
vim.system = function(args, options, callback)
  calls[#calls + 1] = { args = args, options = options }
  if args[1] == 'gh' then
    return { wait = function() return gh_result end }
  end
  local result = vim.tbl_contains(args, 'https://api.github.com/copilot_internal/v2/token')
    and exchange_result or { code = 0, stdout = '{"data":[{"id":"gpt-4o"}]}\n200' }
  vim.schedule(function() callback(result) end)
end
local function reset()
  for _, name in ipairs({ 'COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN' }) do vim.env[name] = nil end
  for _, name in ipairs({ 'apps.json', 'hosts.json' }) do vim.fn.delete(temp .. '/github-copilot/' .. name) end
  calls, gh_available = {}, false
  gh_result = { code = 0, stdout = 'cli-token\n' }
  exchange_result = { code = 0, stdout = vim.json.encode({ token = 'session-token', expires_at = now + 300 }) .. '\n200' }
  package.loaded['codeit.providers'] = nil
  package.loaded['codeit.providers.copilot'] = nil
  package.loaded['codeit.providers.copilot.auth'] = nil
  return require('codeit.providers')
end
local function credentials(name, data)
  vim.fn.writefile({ vim.json.encode(data) }, temp .. '/github-copilot/' .. name)
end
local function models(providers)
  local done, result, failure, detail
  providers.models('copilot', function(value, err, response)
    done, result, failure, detail = true, value, err, response
  end)
  assert(vim.wait(2000, function() return done end), 'authentication timed out')
  return result, failure, detail
end
local function expect_token(providers, token)
  local result, err = models(providers)
  assert(not err and result[1].id == 'gpt-4o', tostring(err))
  local exchange = calls[#calls - 1]
  assert(vim.tbl_contains(exchange.args, 'Authorization: token ' .. token), 'wrong credential selected')
  assert(vim.tbl_contains(exchange.args, '--write-out'))
  assert(vim.tbl_contains(calls[#calls].args, 'Authorization: Bearer session-token'))
end

-- Explicit credentials override saved logins and CLI credentials; skip empty values.
local providers = reset()
vim.env.COPILOT_GITHUB_TOKEN, vim.env.GH_TOKEN, vim.env.GITHUB_TOKEN = 'explicit-token', 'gh-token', 'github-token'
credentials('apps.json', { ['github.com:app'] = { oauth_token = 'saved-token' } })
gh_available = true
expect_token(providers, 'explicit-token')
assert(#calls == 2, 'explicit credentials must not invoke gh')
providers = reset()
vim.env.COPILOT_GITHUB_TOKEN, vim.env.GH_TOKEN, vim.env.GITHUB_TOKEN = '', 'gh-token', 'github-token'
expect_token(providers, 'gh-token')
providers = reset()
vim.env.GH_TOKEN, vim.env.GITHUB_TOKEN = '', 'github-token'
expect_token(providers, 'github-token')

-- Copilot logins win over gh; support both current and legacy credential files.
providers = reset()
credentials('apps.json', {
  ['enterprise.example:app'] = { oauth_token = 'wrong-host-token' },
  ['github.com:app'] = { oauth_token = 'apps-token' },
})
credentials('hosts.json', { ['github.com'] = { oauth_token = 'hosts-token' } })
gh_available = true
expect_token(providers, 'apps-token')
assert(#calls == 2, 'saved Copilot credentials must not invoke gh')
providers = reset()
vim.fn.writefile({ 'invalid json' }, temp .. '/github-copilot/apps.json')
credentials('hosts.json', { ['github.com'] = { oauth_token = 'hosts-token' } })
expect_token(providers, 'hosts-token')
providers = reset()
credentials('apps.json', { { oauth_token = 'not-a-host-entry' } })
credentials('hosts.json', { ['github.com'] = { oauth_token = 'hosts-token' } })
expect_token(providers, 'hosts-token')
providers = reset()
credentials('apps.json', {
  ['github.com'] = { oauth_token = vim.NIL },
  ['github.com.evil:app'] = { oauth_token = 'wrong-host-token' },
})
credentials('hosts.json', { ['github.com'] = { oauth_token = '' } })
gh_available = true
expect_token(providers, 'cli-token')
assert(vim.deep_equal(calls[1].args, { 'gh', 'auth', 'token', '--hostname', 'github.com' }))
providers = reset()
local result, err = models(providers)
assert(not result and err:find('Copilot requires', 1, true) and #calls == 0)
providers = reset()
gh_available, gh_result = true, { code = 1, stdout = '', stderr = 'not logged in' }
result, err = models(providers)
assert(not result and err:find('Copilot requires', 1, true) and #calls == 1)

-- Reuse the session token until the refresh margin, then exchange again.
providers = reset()
vim.env.COPILOT_GITHUB_TOKEN = 'oauth-token'
expect_token(providers, 'oauth-token')
result, err = models(providers)
assert(result and not err and #calls == 3, 'session token should be cached')
now = now + 241
expect_token(providers, 'oauth-token')
assert(#calls == 5, 'session token should refresh before expiry')

-- HTTP and transport errors are actionable, never treated as successful exchanges.
for _, case in ipairs({
  { stdout = '{"message":"Bad credentials"}\n401', contains = 'HTTP 401: Bad credentials' },
  { stdout = '{"error":{"message":"Forbidden"}}\n403', contains = 'HTTP 403: Forbidden' },
  { stdout = '{"error":{"msg":"Subscription required"}}\n403', contains = 'Subscription required' },
  { stdout = '<html>Unavailable</html>\n503', contains = 'HTTP 503' },
  { stdout = 'not json\n200', contains = 'Invalid JSON response' },
  { stdout = '{}', contains = 'Invalid HTTP response' },
  { stdout = '{"token":null}\n200', contains = 'no valid Copilot token' },
  { stdout = '{"token":""}\n200', contains = 'no valid Copilot token' },
  { stdout = '{"token":123}\n200', contains = 'no valid Copilot token' },
  { stdout = '{}\n200', contains = 'no valid Copilot token' },
  { code = 28, stderr = '', contains = 'curl exited with code 28' },
  { code = 6, stderr = 'Could not resolve host', contains = 'Could not resolve host' },
}) do
  providers = reset()
  vim.env.COPILOT_GITHUB_TOKEN = 'oauth-token'
  exchange_result = { code = case.code or 0, stdout = case.stdout or '', stderr = case.stderr }
  local detail
  result, err, detail = models(providers)
  assert(not result and err:find(case.contains, 1, true), tostring(err))
  assert(detail == nil and #calls == 1, 'failed exchanges must not send API requests or return credential bodies')
  if case.stdout and (case.stdout:find('\n401', 1, true) or case.stdout:find('\n403', 1, true)) then
    assert(err:find('Copilot OAuth token', 1, true), 'credential rejection needs recovery guidance')
  end
  exchange_result = { code = 0, stdout = '{"token":"session-token"}\n200' }
  expect_token(providers, 'oauth-token')
  assert(#calls == 3, 'failed exchanges must not be cached')
end

-- Redact echoed credentials, including failed responses that happen to contain a token.
providers = reset()
vim.env.COPILOT_GITHUB_TOKEN = 'oauth-token'
exchange_result = { code = 0, stdout = '{"token":"secret-session","message":"Rejected oauth-token secret-session"}\n403' }
local failure
providers.chat({ provider = 'copilot', model = 'gpt-4o' }, {}, {}, function(_, error) failure = error end)
assert(vim.wait(2000, function() return failure ~= nil end))
assert(failure:find('[redacted]', 1, true) and not failure:find('oauth-token', 1, true)
  and not failure:find('secret-session', 1, true))
local log = table.concat(vim.fn.readfile(vim.fn.stdpath('state') .. '/codeit/provider-errors.log'), '\n')
assert(not log:find('oauth-token', 1, true) and not log:find('secret-session', 1, true))

vim.system, vim.fn.executable, os.time = original_system, original_executable, original_time
for _, name in ipairs(env_names) do vim.env[name] = original_env[name] end
vim.fn.delete(temp, 'rf')
print('codeit Copilot authentication tests passed')
