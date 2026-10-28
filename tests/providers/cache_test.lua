vim.opt.runtimepath:prepend(vim.fn.getcwd())
local captured
package.loaded['codeit.providers.http'] = {
  get = function(_, _, callback)
    callback({ data = {
      { id = 'claude-sonnet-test', supported_endpoints = { '/chat/completions' } },
      { id = 'gpt-test', supported_endpoints = { '/responses' } },
    } })
  end,
  post = function(url, headers, body, callback)
    captured = { url = url, headers = headers, body = body }
    callback({ choices = { { message = { role = 'assistant', content = 'ok' } } },
      status = 'completed', output = {
        { type = 'message', role = 'assistant', content = { { type = 'output_text', text = 'ok' } } },
      } })
  end,
}
package.loaded['codeit.providers.codex.auth'] = {
  credentials = function() return { token = 'test-token' } end,
  headers = function() return {} end,
  redact = function(value) return value end,
  url = 'https://codex.test',
}
package.loaded['codeit.providers.copilot.auth'] = {
  token = function(callback) callback('test-token') end,
}
vim.env.OPENROUTER_API_KEY = 'test-key'
local transcript = {
  { role = 'system', content = 'base' },
  { role = 'system', content = { { type = 'text', text = 'workspace instructions' } } },
  { role = 'user', content = 'question' },
  { role = 'assistant', content = vim.NIL, tool_calls = {
    { id = 'call', type = 'function', ['function'] = { name = 'read_file', arguments = '{}' } },
  } },
  { role = 'tool', tool_call_id = 'call', content = 'result' },
  { role = 'user', content = {
    { type = 'text', text = 'follow up' },
    { type = 'image_url', image_url = { url = 'https://example.test/image.png' } },
  } },
}
local original = vim.deepcopy(transcript)
local tools = { { type = 'function', ['function'] = {
  name = 'read_file', description = 'Read', parameters = { type = 'object' },
} } }
local key = string.rep('a', 64)
local function request(provider, model, options, cache_key)
  captured = nil
  require('codeit.providers.' .. provider).chat({ model = model, options = options, cache_key = cache_key },
    transcript, tools, function(_, err) assert(not err, err) end)
  assert(captured)
  assert(vim.deep_equal(transcript, original), 'caching must not mutate the transcript')
  return captured.body
end
local function markers(body)
  local result = {}
  for index, message in ipairs(body.messages) do
    if type(message.content) == 'table' then
      for _, part in ipairs(message.content) do
        if part.cache_control then
          assert(part.type == 'text' and part.cache_control.type == 'ephemeral')
          assert(part.cache_control.ttl == nil, 'do not opt into an extended TTL')
          result[#result + 1] = index
        end
      end
    end
  end
  return result
end
local body = request('openrouter', 'anthropic/claude-sonnet-4', nil, key)
assert(body.session_id == key and body.prompt_cache_key == nil)
assert(vim.deep_equal(markers(body), { 2, 5, 6 }))
assert(body.messages[6].content[2].type == 'image_url')
assert(vim.deep_equal(body.tools, tools))
for _, model in ipairs({ 'qwen/qwen3-coder-plus', 'deepseek/deepseek-v3.2', 'qwen/qwen-plus:floor' }) do
  assert(#markers(request('openrouter', model, nil, key)) == 3)
end
for _, model in ipairs({ 'openai/gpt-5', 'google/gemini-test', 'qwen/qwen3.5-plus-02-15', 'deepseek/deepseek-chat' }) do
  body = request('openrouter', model, nil, key)
  assert(#markers(body) == 0, model)
  assert(vim.deep_equal(body.messages, transcript), 'automatic-cache models need no content conversion')
end
body = request('openrouter', 'anthropic/claude-sonnet-4', { preferred_provider = 'Anthropic', allow_fallbacks = false }, key)
assert(body.provider.order[1] == 'Anthropic' and body.provider.allow_fallbacks == false)
assert(body.session_id == key, 'cache affinity must not replace explicit routing options')
assert(request('openrouter', 'openai/gpt-5').session_id == nil)
assert(request('openai', 'gpt-5', nil, key).prompt_cache_key == key)
assert(request('openai', 'gpt-5', { base_url = 'https://api.openai.com/v1///' }, key).prompt_cache_key == key)
assert(request('openai', 'local', { base_url = 'http://localhost:1234/v1', api_key_env = '' }, key).prompt_cache_key == nil)
assert(request('openai', 'gpt-5').prompt_cache_key == nil)
assert(request('codex', 'gpt-5-codex', nil, key).prompt_cache_key == key)
body = request('copilot', 'claude-sonnet-test', nil, key)
assert(body.prompt_cache_key == key and #markers(body) == 3)
body = request('copilot', 'gpt-test', nil, key)
assert(body.prompt_cache_key == key and body.input and not body.messages)

-- Older Neovim versions convert NUL-containing Lua strings to Vimscript Blobs.
local sha256 = vim.fn.sha256
vim.fn.sha256 = function(value)
  assert(type(value) == 'string' and not value:find('\0', 1, true), 'sha256 requires a NUL-free string')
  return sha256(value)
end
-- Cache identity is independent of mutable messages, model, and feature settings.
local defaults = require('codeit.settings.defaults')
local session = { config = vim.deepcopy(defaults), chat_id = 'chat-a', workspace = '/workspace/a' }
local helpers = {}
require('codeit.chat.session').attach({}, session, helpers)
local main = helpers.request_config().cache_key
assert(#main == 64 and main:match('^[a-f0-9]+$'))
assert(main == helpers.request_config().cache_key)
local feature = helpers.request_config('subagent').cache_key
assert(feature ~= main and feature == helpers.request_config('subagent').cache_key)
session.chat_model = 'different-model'
assert(main == helpers.request_config().cache_key)
session.chat_id = 'chat-b'
assert(main ~= helpers.request_config().cache_key)
session.chat_id = 'chat-a'
assert(main == helpers.request_config().cache_key, 'resuming the chat must restore its identity')
session.workspace = '/workspace/b'
assert(main ~= helpers.request_config().cache_key)
session.chat_id = nil
assert(helpers.request_config().cache_key == nil)
vim.fn.sha256 = sha256
print('codeit provider cache tests passed')
