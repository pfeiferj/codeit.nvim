vim.opt.runtimepath:prepend(vim.fn.getcwd())
local original_system, original_token = vim.system, vim.env.COPILOT_GITHUB_TOKEN
vim.env.COPILOT_GITHUB_TOKEN = 'test-oauth'
local calls = {}
local catalogs = {
  ['api.githubcopilot.com'] = { data = {
    { id = 'gpt-6-luna', supported_endpoints = { '/responses' } },
    { id = 'both', supported_endpoints = { '/responses', '/chat/completions' } },
    { id = 'legacy' },
    { id = 'unsupported', supported_endpoints = { '/messages' } },
    { id = 'no-endpoints', supported_endpoints = {} },
  } },
  ['api.business.githubcopilot.com'] = { data = {
    { id = 'gpt-6-luna', supported_endpoints = { '/chat/completions' } },
  } },
}
local response = { status = 'completed', output = {
  { type = 'message', role = 'assistant', content = { { type = 'output_text', text = 'hello' } } },
} }
local status = '200'
vim.system = function(args, options, callback)
  calls[#calls + 1] = { args = args, options = options }
  local url, data = args[#args]
  if url == 'https://api.github.com/copilot_internal/v2/token' then
    data = { token = 'test-session', expires_at = os.time() + 3600 }
  elseif url:match('/models$') then
    data = catalogs[url:match('^https://([^/]+)')]
  elseif url:match('/chat/completions$') then
    data = { choices = { { message = { role = 'assistant', content = 'legacy answer' } } } }
  else
    assert(url:match('/responses$'), url)
    data = response
  end
  local http_status = url:match('/responses$') and status or '200'
  vim.schedule(function() callback({ code = 0, stdout = vim.json.encode(data) .. '\n' .. http_status }) end)
end
local providers = require('codeit.providers')
local function chat(model, messages, tools, options)
  local done, message, failure, usage
  providers.chat({ provider = 'copilot', model = model, options = options },
    messages or { { role = 'user', content = 'hello' } }, tools or {}, function(value, err, billing)
      done, message, failure, usage = true, value, err, billing
    end)
  assert(vim.wait(2000, function() return done end), 'chat timed out')
  if failure then assert(usage == nil, 'failed requests must not expose usage') end
  return message, failure, usage
end
local message, err = chat('gpt-6-luna', {
  { role = 'system', content = 'Be helpful' }, { role = 'user', content = 'hello' },
}, require('codeit.tools').specs)
assert(not err and message.content == 'hello', tostring(err))
assert(#calls == 3, 'manual model ID must fetch the catalog before sending a chat')
assert(calls[2].args[#calls[2].args] == 'https://api.githubcopilot.com/models')
assert(calls[3].args[#calls[3].args] == 'https://api.githubcopilot.com/responses')
assert(vim.tbl_contains(calls[3].args, 'Authorization: Bearer test-session'))
assert(vim.tbl_contains(calls[3].args, 'Copilot-Integration-Id: vscode-chat'))
local payload = vim.json.decode(calls[3].options.stdin)
assert(payload.model == 'gpt-6-luna' and payload.messages == nil)
assert(payload.input[1].role == 'system' and payload.input[1].content == 'Be helpful')
assert(payload.stream == false and payload.store == false)
assert(payload.include[1] == 'reasoning.encrypted_content')
assert(payload.reasoning == nil and payload.reasoning_effort == nil)
assert(payload.tools[1].name == require('codeit.tools').specs[1]['function'].name)
assert(payload.tools[1]['function'] == nil and payload.tools[1].strict == false)
assert(calls[3].options.stdin:find('"properties":{}', 1, true), 'empty schemas must remain JSON objects')
for _, model in ipairs({ 'gpt-6-luna', 'both' }) do
  for _, effort in ipairs(require('codeit.settings').efforts) do
    local answer, failure = chat(model, nil, nil, { effort = effort })
    assert(answer and not failure, tostring(failure))
    local body = vim.json.decode(calls[#calls].options.stdin)
    if model == 'gpt-6-luna' then
      assert(body.reasoning_effort == nil)
      if effort == '' then assert(body.reasoning == nil)
      else assert(body.reasoning.effort == effort) end
    else
      assert(body.reasoning == nil)
      assert(body.reasoning_effort == (effort ~= '' and effort or nil))
    end
  end
end
assert(vim.tbl_contains(calls[3].args, 'X-GitHub-Api-Version: 2026-08-01'))
response.usage = { input_tokens = 100, output_tokens = 25, total_tokens = 125,
  input_tokens_details = { cached_tokens = 70 } }
response.copilot_usage = { total_nano_aiu = '360000' }
local _, _, usage = chat('gpt-6-luna')
assert(usage.cost == 360000 / 100000000000)
assert(usage.prompt_tokens == 100 and usage.completion_tokens == 25 and usage.total_tokens == 125)
assert(usage.cached_tokens == 70)
local capped_done
providers.chat({ provider = 'copilot', model = 'gpt-6-luna', max_output_tokens = 256 },
  { { role = 'user', content = 'summarize' } }, {}, function(_, failure)
    assert(not failure); capped_done = true
  end)
assert(vim.wait(2000, function() return capped_done end))
assert(vim.json.decode(calls[#calls].options.stdin).max_output_tokens == 256)
response.copilot_usage.total_nano_aiu = 0
_, _, usage = chat('gpt-6-luna')
assert(usage.cost == 0, 'a reported zero charge must not be treated as missing')
response.copilot_usage = nil
_, _, usage = chat('gpt-6-luna')
assert(usage.cost == nil and usage.prompt_tokens == 100, 'token usage must survive missing billing')
response.usage = nil
_, _, usage = chat('gpt-6-luna')
assert(usage == nil, 'absent usage must remain unknown')

-- Normalize parallel calls using call_id (not the Responses output item's id).
local reasoning = { type = 'reasoning', id = 'rs_1', summary = {}, encrypted_content = 'encrypted-data' }
response = { status = 'completed', output = {
  reasoning,
  { type = 'message', role = 'assistant', content = { { type = 'output_text', text = 'Checking' } } },
  { type = 'function_call', id = 'fc_1', call_id = 'call_1', name = 'read_file', arguments = '{"path":"README.md"}' },
  { type = 'function_call', id = 'fc_2', call_id = 'call_2', name = 'list_buffers', arguments = '{}' },
} }
local before = #calls
message, err = chat('gpt-6-luna')
assert(not err and #calls == before + 1, 'catalog should be reused across chat requests')
assert(message.content == 'Checking' and #message.tool_calls == 2)
assert(message.tool_calls[1].id == 'call_1' and message.tool_calls[2].id == 'call_2')
assert(message.tool_calls[1]['function'].arguments == '{"path":"README.md"}')
assert(vim.deep_equal(message._copilot_reasoning, { reasoning }))
response = { status = 'completed', output = {
  { type = 'message', role = 'assistant', content = { { type = 'output_text', text = 'Done' } } },
} }
local transcript = {
  { role = 'system', content = 'Be helpful' }, { role = 'user', content = 'check' }, message,
  { role = 'tool', tool_call_id = 'call_1', content = 'file contents' },
  { role = 'tool', tool_call_id = 'call_2', content = 'buffers' },
}
local snapshot = vim.json.encode(transcript)
local answer = chat('gpt-6-luna', transcript)
payload = vim.json.decode(calls[#calls].options.stdin)
assert(answer.content == 'Done' and answer.tool_calls == nil)
assert(payload.tools == nil and payload.tool_choice == nil, 'tool-free secondary requests must remain tool-free')
assert(payload.input[3].type == 'reasoning' and payload.input[3].encrypted_content == 'encrypted-data')
assert(payload.input[4].role == 'assistant' and payload.input[4].content == 'Checking')
assert(payload.input[5].type == 'function_call' and payload.input[5].call_id == 'call_1')
assert(payload.input[6].type == 'function_call' and payload.input[6].call_id == 'call_2')
assert(payload.input[7].type == 'function_call_output' and payload.input[7].call_id == 'call_1')
assert(payload.input[7].output == 'file contents' and payload.input[8].output == 'buffers')
assert(snapshot == vim.json.encode(transcript), 'conversion must not mutate shared messages')

-- Each API host keeps its own endpoint metadata.
answer, err = chat('gpt-6-luna', transcript, nil, { api_host = 'api.business.githubcopilot.com' })
assert(not err and answer.content == 'legacy answer')
payload = vim.json.decode(calls[#calls].options.stdin)
assert(payload.messages[3]._copilot_reasoning == nil, 'Responses metadata must not leak into chat completions')
assert(payload.messages[3].tool_calls[1].id == 'call_1')
assert(snapshot == vim.json.encode(transcript), 'stripping private metadata must not mutate shared messages')
assert(calls[#calls - 1].args[#calls[#calls - 1].args] == 'https://api.business.githubcopilot.com/models')
assert(calls[#calls].args[#calls[#calls].args] == 'https://api.business.githubcopilot.com/chat/completions')
answer = chat('gpt-6-luna')
assert(answer.content == 'Done' and calls[#calls].args[#calls[#calls].args] == 'https://api.githubcopilot.com/responses')
for _, model in ipairs({ 'both', 'legacy', 'manual-unknown' }) do
  answer, err = chat(model)
  assert(not err and answer.content == 'legacy answer')
  assert(calls[#calls].args[#calls[#calls].args] == 'https://api.githubcopilot.com/chat/completions')
end
for _, model in ipairs({ 'unsupported', 'no-endpoints' }) do
  before = #calls
  answer, err = chat(model)
  assert(not answer and err:find('does not advertise a supported chat endpoint', 1, true))
  assert(#calls == before, 'unsupported endpoints must not trigger a completion request')
end

-- The picker refreshes routing metadata; no hardcoded model-name heuristics.
catalogs['api.githubcopilot.com'].data[2].supported_endpoints = { '/responses' }
local loaded
providers.models('copilot', function(models, failure) assert(not failure); loaded = models end)
assert(vim.wait(2000, function() return loaded ~= nil end))
answer = chat('both')
assert(answer.content == 'Done')
assert(calls[#calls].args[#calls[#calls].args] == 'https://api.githubcopilot.com/responses')

-- Failed and malformed Responses must never execute partial tool batches or silently retry.
for _, case in ipairs({
  { response = { error = { message = 'Not allowed' } }, status = '400', error = 'HTTP 400: Not allowed' },
  { response = { status = 'failed', error = { message = 'Failed' } }, error = 'Copilot response failed: Failed' },
  { response = { status = 'incomplete', incomplete_details = { reason = 'max_output_tokens' }, output = {} },
    error = 'Copilot response incomplete: max_output_tokens' },
  { response = { status = 'completed', output = {} }, error = 'Response has no assistant message' },
  { response = { output = { { type = 'function_call', name = 'read_file', arguments = '{}' } } },
    error = 'Malformed tool call from Copilot Responses' },
  { response = { output = { vim.NIL } }, error = 'Malformed output item from Copilot Responses' },
  { response = { output = { 'invalid' } }, error = 'Malformed output item from Copilot Responses' },
  { response = { output = { { type = 'message', role = 'assistant', content = vim.NIL } } },
    error = 'Malformed message content from Copilot Responses' },
  { response = { output = { { type = 'message', role = 'assistant' } } },
    error = 'Malformed message content from Copilot Responses' },
  { response = { output = { { type = 'message', role = 'assistant', content = { text = 'invalid' } } } },
    error = 'Malformed message content from Copilot Responses' },
  { response = { output = { { type = 'message', role = 'assistant', content = { vim.NIL } } } },
    error = 'Malformed content part from Copilot Responses' },
  { response = { output = {
    { type = 'function_call', call_id = 'call_1', name = 'read_file', arguments = '{}' },
    { type = 'message', role = 'assistant', content = { { type = 'output_text', text = vim.NIL } } },
  } }, error = 'Malformed text from Copilot Responses' },
  { response = { output = { { type = 'message', role = 'assistant',
    content = { { type = 'refusal', refusal = vim.NIL } } } } },
    error = 'Malformed refusal from Copilot Responses' },
}) do
  response, status = case.response, case.status or '200'
  before = #calls
  answer, err = chat('gpt-6-luna')
  assert(not answer and err == case.error, tostring(err))
  assert(#calls == before + 1, 'errors must not retry a possibly billable chat')
end

local adapter = require('codeit.providers.protocols.responses')
local body = adapter.body('model', {
  { role = 'user', content = {
    { type = 'text', text = 'describe' },
    { type = 'image_url', image_url = { url = 'data:image/png;base64,example', detail = 'low' } },
  } },
  { role = 'assistant', content = { { type = 'text', text = 'description' } } },
})
assert(body.input[1].content[1].type == 'input_text')
assert(body.input[1].content[2].type == 'input_image' and body.input[1].content[2].detail == 'low')
assert(body.input[2].content[1].type == 'output_text')
body, err = adapter.body('model', { { role = 'user', content = { { type = 'unsupported' } } } })
assert(not body and err:find('Unsupported Copilot Responses content part', 1, true))
message = adapter.message({ output = {
  { type = 'function_call', call_id = 'call', name = 'read_file', arguments = '{}' },
} })
assert(message.content == vim.NIL and #message.tool_calls == 1)
message = adapter.message({ output = {
  { type = 'message', role = 'assistant', content = { { type = 'refusal', refusal = 'Cannot do that' } } },
} })
assert(message.content == 'Cannot do that')

vim.system, vim.env.COPILOT_GITHUB_TOKEN = original_system, original_token
print('codeit Copilot Responses tests passed')
