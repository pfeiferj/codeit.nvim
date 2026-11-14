vim.opt.runtimepath:prepend(vim.fn.getcwd())
local provider = require('codeit.providers.openrouter')
local http = require('codeit.providers.http')
local original_post, original_key = http.post, vim.env.OPENROUTER_API_KEY
vim.env.OPENROUTER_API_KEY = 'test-key'
local body, streaming
http.post = function(_, _, payload, callback, stream)
  body, streaming = payload, stream
  callback({ choices = { { message = { role = 'assistant', content = '{"ok":true}' } } } })
end
local tools = { { type = 'function', ['function'] = { name = 'test' } } }
local messages = { { role = 'user', content = 'Return JSON' } }
local function request(value, on_text, tool_choice)
  local answer
  provider.chat({ model = 'test', tool_choice = tool_choice, max_output_tokens = 256, options = {
    response_healing = value, routing_mode = 'price', allow_fallbacks = false,
  } }, messages, tools, function(message, err)
    assert(not err, tostring(err))
    answer = message
  end, on_text)
  assert(answer.content == '{"ok":true}')
  assert(body.max_tokens == 256 and body.usage.include)
  assert(body.provider.sort == 'price' and body.provider.allow_fallbacks == false)
  assert(vim.deep_equal(body.tools, tools) and vim.deep_equal(body.messages, messages))
  assert(body.response_healing == nil, 'local option must not leak into the API body')
end
for _, on_text in ipairs({ false, function() error('must not stream healed responses') end }) do
  request(true, on_text or nil)
  assert(vim.deep_equal(body.plugins, { { id = 'response-healing' } }))
  assert(vim.deep_equal(body.response_format, { type = 'json_object' }))
  assert(body.stream == nil and body.stream_options == nil and streaming == nil)
  for _, value in ipairs({ false, '' }) do
    request(value, on_text or nil)
    assert(body.plugins == nil and body.response_format == nil)
    assert((streaming ~= nil) == (on_text ~= false))
    assert((body.stream == true) == (on_text ~= false))
  end
end
request(nil, function() end)
assert(body.plugins == nil and body.response_format == nil and streaming ~= nil)
request(true, nil, 'required')
assert(body.tool_choice == 'required' and body.plugins == nil and body.response_format == nil,
  'required tool responses must not use JSON text healing')
messages = { { role = 'user', content = {
  { type = 'file', file = { filename = 'report.pdf', file_data = 'data:application/pdf;base64,JVBERi0=' } },
  { type = 'input_audio', input_audio = { data = 'SUQz', format = 'mp3' } },
} } }
request(false)
assert(vim.deep_equal(body.plugins, { { id = 'file-parser', pdf = { engine = 'native' } } }))
assert(body.messages[1].content[2].input_audio.format == 'mp3')
request(true)
assert(#body.plugins == 2 and body.plugins[1].id == 'response-healing')
assert(body.plugins[2].pdf.engine == 'native', 'native PDFs must not silently switch to OCR/text extraction')
http.post, vim.env.OPENROUTER_API_KEY = original_post, original_key
print('OpenRouter response healing requests: passed')
