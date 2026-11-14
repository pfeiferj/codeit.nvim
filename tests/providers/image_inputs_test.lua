vim.opt.runtimepath:prepend(vim.fn.getcwd())
local chat = require('codeit.providers.protocols.chat')
local responses = require('codeit.providers.protocols.responses')
local image = { type = 'image_url', image_url = { url = 'data:image/png;base64,aGVsbG8=', detail = 'auto' } }
local messages = {
  { role = 'user', content = { { type = 'text', text = 'Inspect this' }, image } },
  { role = 'assistant', tool_calls = {
    { id = 'a', ['function'] = { name = 'read_image', arguments = '{}' } },
    { id = 'b', ['function'] = { name = 'read_image', arguments = '{}' } },
  } },
  { role = 'tool', tool_call_id = 'a', content = { { type = 'text', text = 'Read first.png' }, image } },
  { role = 'tool', tool_call_id = 'b', content = { { type = 'text', text = 'Read second.png' }, image } },
  { role = 'assistant', content = 'Both look fine' },
}
local before = vim.json.encode(messages)
local body = chat.body('vision', messages)
assert(#body.messages == 6)
assert(body.messages[1].content[2].image_url.url == image.image_url.url)
assert(body.messages[3].role == 'tool' and body.messages[3].content == 'Read first.png')
assert(body.messages[4].role == 'tool' and body.messages[4].content == 'Read second.png')
assert(body.messages[5].role == 'user' and #body.messages[5].content == 4)
assert(body.messages[5].content[1].text:find('tool call a', 1, true))
assert(body.messages[5].content[3].text:find('tool call b', 1, true))
for _, provider in ipairs({ 'Copilot', 'Codex' }) do
  local response, err = responses.body('vision', messages, nil, provider)
  assert(response, err)
  local input = response.input
  assert(input[1].content[2].type == 'input_image')
  assert(input[1].content[2].detail == 'auto')
  assert(input[4].type == 'function_call_output' and input[4].output == 'Read first.png')
  assert(input[5].type == 'function_call_output' and input[5].output == 'Read second.png')
  assert(input[6].role == 'user' and input[6].content[2].type == 'input_image')
  assert(input[6].content[4].image_url == image.image_url.url)
end
assert(vim.json.encode(messages) == before, 'serialization must not mutate saved history')
local trailing = chat.body('vision', vim.list_slice(messages, 1, 4))
assert(trailing.messages[5].role == 'user', 'flush image results at end of tool batch')
local plain = { { role = 'tool', tool_call_id = 'x', content = 'ordinary text' } }
assert(vim.deep_equal(chat.body('vision', plain).messages, plain))
local compaction = require('codeit.context.compaction')
assert(compaction.tokens({ content = { image } }) > 4096)
local large = vim.deepcopy(image)
large.image_url.url = large.image_url.url .. string.rep('A', 100000)
assert(compaction.tokens({ content = { large } }) == compaction.tokens({ content = { image } }),
  'base64 transport bytes must not be counted as text tokens')
local reference = require('codeit.images').reference(messages)
assert(not vim.json.encode(reference):find('base64', 1, true))
assert(reference[1].content[1].text == 'Inspect this')
assert(reference[1].content[2].text:find('Image content omitted', 1, true))
assert(vim.json.encode(messages) == before, 'text references must not alter native image history')
print('image_inputs_test: passed')
