vim.opt.runtimepath:prepend(vim.fn.getcwd())
local temp = vim.fn.tempname()
vim.fn.mkdir(temp, 'p')
local original_home, original_system = vim.env.CODEX_HOME, vim.system
vim.env.CODEX_HOME = temp
local codex = require('codeit.providers.codex.auth')
local providers = require('codeit.providers')
local function jwt(value)
  local encoded = vim.base64.encode(vim.json.encode(value)):gsub('+', '-'):gsub('/', '_'):gsub('=+$', '')
  return 'header.' .. encoded .. '.signature'
end
local token = jwt({ exp = os.time() + 3600 })
local id_token = jwt({ ['https://api.openai.com/auth'] = { chatgpt_account_id = 'claim-account' } })
local function login(tokens, mode)
  vim.fn.writefile({ vim.json.encode({ auth_mode = mode, tokens = tokens }) }, temp .. '/auth.json')
end
local function valid_login()
  login({ access_token = token, id_token = id_token, refresh_token = 'private-refresh-token', account_id = 'test-account' }, 'chatgpt')
end
local auth, err = codex.credentials()
assert(not auth and err:find('file-backed', 1, true))
vim.fn.writefile({ 'invalid JSON private-secret' }, temp .. '/auth.json')
auth, err = codex.credentials()
assert(not auth and not err:find('private-secret', 1, true))
for _, invalid in ipairs({
  { access_token = token },
  { access_token = token .. '\n', account_id = 'account' },
  { access_token = token, account_id = 'account\nInjected: header' },
  { access_token = jwt({ exp = os.time() - 1 }), account_id = 'account' },
}) do
  login(invalid)
  auth, err = codex.credentials()
  assert(not auth and err)
end
login({ access_token = token, account_id = 'account' }, 'apikey')
auth, err = codex.credentials()
assert(not auth and err:find('not an API key', 1, true))
login({ access_token = token, id_token = id_token })
assert(codex.credentials().account_id == 'claim-account', 'older credentials can use the JWT account claim')
valid_login()
assert(codex.credentials().account_id == 'test-account')
local initial_auth_file = table.concat(vim.fn.readfile(temp .. '/auth.json'), '\n')

local calls = {}
local catalog = { models = {
  { slug = 'z-codex', display_name = 'Last', context_window = 128000 },
  { slug = 'gpt-5.3-codex', display_name = 'Codex', context_window = 272000 },
} }
local response = { status = 'completed', output = {
  { type = 'reasoning', id = 'reasoning-id', encrypted_content = 'encrypted-reasoning' },
  { type = 'message', role = 'assistant', content = { { type = 'output_text', text = 'hello' } } },
  { type = 'function_call', call_id = 'call-1', name = 'list_windows', arguments = '{}' },
}, usage = { input_tokens = 100, output_tokens = 25, total_tokens = 125,
  input_tokens_details = { cached_tokens = 60 }, cost = 99 }, copilot_usage = { total_nano_aiu = 1000 } }
local status, failure_body, truncated = '200', nil, false
vim.system = function(args, options, callback)
  calls[#calls + 1] = { args = args, body = options.stdin and vim.json.decode(options.stdin) }
  local raw
  if args[#args]:find('/models?', 1, true) then
    raw = vim.json.encode(failure_body or catalog) .. '\n' .. status
  elseif status ~= '200' then
    raw = vim.json.encode(failure_body) .. '\n' .. status
  else
    raw = 'HTTP/2 200\r\ncontent-type: text/event-stream\r\n\r\n'
      .. 'data: ' .. vim.json.encode({ type = 'response.output_text.delta', delta = 'hel' }) .. '\n\n'
      .. 'data: ' .. vim.json.encode({ type = 'response.output_text.delta', delta = 'lo' }) .. '\n\n'
    if not truncated then
      raw = raw .. 'data: ' .. vim.json.encode({ type = 'response.' .. response.status, response = response }) .. '\n\n'
    end
    raw = raw .. '\n200'
  end
  if options.stdout then
    -- Exercise arbitrary SSE chunk boundaries, including split CRLFs.
    for i = 1, #raw, 17 do options.stdout(nil, raw:sub(i, i + 16)) end
    vim.schedule(function() callback({ code = 0, stdout = '', stderr = '' }) end)
  else vim.schedule(function() callback({ code = 0, stdout = raw, stderr = '' }) end) end
  return { kill = function() end }
end
local models, model_error
providers.models('codex', function(result, failure) models, model_error = result, failure end)
assert(vim.wait(2000, function() return models ~= nil or model_error ~= nil end))
assert(not model_error and models[1].id == 'gpt-5.3-codex' and models[1].name == 'Codex')
assert(models[1].context_length == 272000)
assert(calls[1].args[#calls[1].args] == codex.url .. '/models?client_version=' .. codex.client_version)
assert(vim.tbl_contains(calls[1].args, 'ChatGPT-Account-Id: test-account'))
assert(vim.tbl_contains(calls[1].args, 'Authorization: Bearer ' .. token))
local limit
providers.context_limit({ provider = 'codex', model = 'gpt-5.3-codex' }, function(value) limit = value end)
assert(vim.wait(2000, function() return limit ~= nil end) and limit == 272000)

local transcript = {
  { role = 'system', content = 'First instruction' },
  { role = 'system', content = { { type = 'text', text = 'Second instruction' } } },
  { role = 'user', content = 'question' },
  { role = 'assistant', content = vim.NIL, _codex_reasoning = {
    { type = 'reasoning', encrypted_content = 'prior-reasoning' },
  }, _copilot_reasoning = { { type = 'reasoning', encrypted_content = 'wrong-provider' } },
    tool_calls = { { id = 'old-call', type = 'function', ['function'] = { name = 'list_windows', arguments = '{}' } } } },
  { role = 'tool', tool_call_id = 'old-call', content = 'result' },
}
local function chat(config, on_text, active)
  local done, answer, failure, usage
  providers.chat(config, transcript, require('codeit.tools').specs, function(message, err, billing)
    done, answer, failure, usage = true, message, err, billing
  end, on_text, active)
  assert(vim.wait(2000, function() return done end), 'chat timed out')
  return answer, failure, usage
end
local previews = {}
local answer, failure, usage = chat({ provider = 'codex', model = 'gpt-5.3-codex',
  options = { effort = 'high', preferred_provider = 'not-for-codex', api_host = 'attacker.example' } },
  function(text) previews[#previews + 1] = text end)
assert(not failure and answer.content == 'hello')
assert(previews[1] == 'hel' and previews[2] == 'hello')
assert(answer.tool_calls[1].id == 'call-1' and answer.tool_calls[1]['function'].name == 'list_windows')
assert(answer._codex_reasoning[1].encrypted_content == 'encrypted-reasoning' and answer._copilot_reasoning == nil)
assert(usage.prompt_tokens == 100 and usage.completion_tokens == 25 and usage.total_tokens == 125)
assert(usage.cached_tokens == 60 and usage.cost == nil, 'subscription usage must not invent a dollar charge')
local body = calls[#calls].body
assert(body.model == 'gpt-5.3-codex' and body.stream == true and body.store == false)
assert(body.instructions == 'First instruction\n\nSecond instruction')
assert(body.reasoning.effort == 'high' and body.provider == nil and body.api_host == nil)
assert(body.input[1].role == 'user')
assert(body.input[2].encrypted_content == 'prior-reasoning')
assert(body.input[3].type == 'function_call' and body.input[3].call_id == 'old-call')
assert(body.input[4].type == 'function_call_output' and body.input[4].output == 'result')
assert(body.tools[1].type == 'function' and body.tools[1].strict == false)
assert(vim.tbl_contains(calls[#calls].args, codex.url .. '/responses'))
assert(vim.tbl_contains(calls[#calls].args, 'Accept: text/event-stream'))
assert(not vim.tbl_contains(calls[#calls].args, 'X-GitHub-Api-Version: 2026-08-01'))
answer, failure = chat({ provider = 'codex', model = 'gpt-5.3-codex', max_output_tokens = 256, options = { effort = '' } })
assert(not failure and answer.content == 'hello', 'internal requests also need SSE parsing without a preview callback')
assert(calls[#calls].body.max_output_tokens == nil and calls[#calls].body.reasoning == nil)

truncated = true
answer, failure = chat({ provider = 'codex', model = 'gpt-5.3-codex' })
assert(not answer and failure:find('before completion', 1, true))
truncated = false
response = { status = 'failed', error = { message = 'rejected ' .. token .. ' private-refresh-token' } }
answer, failure = chat({ provider = 'codex', model = 'gpt-5.3-codex' })
assert(not answer and failure:find('Codex response failed', 1, true))
assert(not failure:find(token, 1, true) and not failure:find('private-refresh-token', 1, true))
status, failure_body = '401', { error = { message = 'expired ' .. token } }
answer, failure = chat({ provider = 'codex', model = 'gpt-5.3-codex' })
assert(not answer and failure:find('codex login', 1, true))
status = '400'
answer, failure = chat({ provider = 'codex', model = 'gpt-5.3-codex' })
assert(not answer and failure:find('[redacted]', 1, true) and not failure:find(token, 1, true))
local log = table.concat(vim.fn.readfile(vim.fn.stdpath('state') .. '/codeit/provider-errors.log'), '\n')
for _, secret in ipairs({ token, id_token, 'private-refresh-token' }) do
  assert(not log:find(secret, 1, true), 'credentials must not appear in provider logs')
end
local before = #calls
login({ access_token = jwt({ exp = os.time() - 1 }), account_id = 'account' })
answer, failure = chat({ provider = 'codex', model = 'gpt-5.3-codex' })
assert(not answer and failure:find('expired', 1, true) and #calls == before)
valid_login()
local canceled_callback = false
providers.chat({ provider = 'codex', model = 'gpt-5.3-codex' }, {}, {},
  function() canceled_callback = true end, nil, function() return false end)
assert(#calls == before and not canceled_callback, 'canceled turns must not make requests')
assert(table.concat(vim.fn.readfile(temp .. '/auth.json'), '\n') == initial_auth_file, 'never modify CLI credentials')

local settings = require('codeit.settings')
local legacy = { provider = 'openrouter', models = { openrouter = 'old-model', copilot = 'gpt-4o' }, request_options = {} }
assert(settings.validate(legacy))
local base = vim.deepcopy(legacy)
base.provider, base.models.codex, base.request_options.codex = 'codex', 'gpt-5.3-codex', { effort = 'high' }
base.model_presets = { reasoning = { provider = 'codex', options = { effort = 'low' } } }
assert(settings.validate(base))
assert(settings.feature_config(base, 'tool_review').options.effort == 'low')
local invalid = vim.deepcopy(base)
invalid.models.codex = nil
assert(not settings.validate(invalid))
for _, options in ipairs({ { effort = 'invalid' }, { api_host = 'attacker.example' }, { service_tier = 'priority' } }) do
  invalid = vim.deepcopy(base)
  invalid.request_options.codex = options
  assert(not settings.validate(invalid))
end
assert(settings.save(legacy, 'global', temp))
local resolved = settings.resolve(base, temp)
assert(resolved.models.openrouter == 'old-model' and resolved.models.codex == 'gpt-5.3-codex')
vim.fn.delete(vim.fn.stdpath('data') .. '/codeit/settings.json')

status, failure_body = '200', nil
response = { status = 'completed', output = {
  { type = 'reasoning', encrypted_content = 'saved-reasoning',
    summary = { { type = 'summary_text', text = 'Codex thought' } } },
  { type = 'message', role = 'assistant', content = { { type = 'output_text', text = 'saved answer' } } },
}, usage = { input_tokens = 20, output_tokens = 5, total_tokens = 25 } }
local plugin = require('codeit')
plugin.setup({ provider = 'codex', max_context_tokens = false, context_review = false })
plugin.open()
assert(plugin.get_settings().models.codex == 'gpt-5.3-codex')
plugin.send('save a Codex conversation')
local history = require('codeit.history')
local saved
assert(vim.wait(2000, function()
  for _, entry in ipairs(history.list(history.workspace())) do
    local chat = history.load(history.workspace(), entry.id)
    if chat and chat.provider == 'codex' and chat.messages[#chat.messages].content == 'saved answer' then
      saved = chat; return true
    end
  end
  return false
end))
assert(saved.tokens_in == 20 and saved.tokens_out == 5 and saved.missing_cost > 0)
assert(saved.messages[#saved.messages]._codex_reasoning[1].encrypted_content == 'saved-reasoning')
assert(table.concat(vim.api.nvim_buf_get_lines(vim.fn.bufnr('codeit://chat'), 0, -1, false), '\n')
  :find('Codex thought', 1, true))
plugin.new()
assert(plugin.resume(saved.id))
assert(plugin.get_settings().provider == 'codex')
assert(vim.tbl_contains(vim.fn.getcompletion('CodeitProvider ', 'cmdline'), 'codex'))
local command = require('codeit.slash_commands').parse('/provider codex')
assert(vim.tbl_contains(command.choices, 'codex'))
local previous_calls = #calls
plugin.send('continue the saved Codex chat')
assert(vim.wait(2000, function() return #calls > previous_calls end))
local replayed = false
for _, item in ipairs(calls[#calls].body.input) do
  if item.encrypted_content == 'saved-reasoning' then replayed = true end
end
assert(replayed, 'resumed chats must replay encrypted Codex reasoning')
assert(vim.wait(2000, function()
  local chat = history.load(history.workspace(), saved.id)
  return chat and chat.tokens_out == 10
end))

local settings_menu = require('codeit.settings_menu')
local original_select = settings_menu.select
local steps = { 'provider', 'codex', 'effort', 'low', 'model', 'gpt-5.3-codex',
  'tool_review', 'effort', 'high', 'back', 'session' }
local applied
settings_menu.select = function(items, _, callback)
  local wanted = table.remove(steps, 1)
  for _, item in ipairs(items) do
    if (type(item) == 'table' and (item.id or item.value or item.label) or item) == wanted then
      return callback(item)
    end
  end
  error('missing settings choice: ' .. tostring(wanted))
end
local draft = plugin.get_settings()
draft.provider = 'openrouter'
require('codeit.settings_picker').show(draft, function(values) applied = values end)
assert(vim.wait(2000, function() return applied ~= nil end))
assert(#steps == 0 and applied.provider == 'codex' and applied.request_options.codex.effort == 'low')
assert(settings.feature_config(applied, 'tool_review').options.effort == 'high')
assert(draft.provider == 'openrouter', 'picker edits must remain draft-only')
settings_menu.select = original_select

vim.system, vim.env.CODEX_HOME = original_system, original_home
vim.fn.delete(temp, 'rf')
vim.cmd('qa!')
