vim.opt.runtimepath:prepend(vim.fn.getcwd())
local chat = require('codeit.providers.protocols.chat')
local responses = require('codeit.providers.protocols.responses')
local image = { type = 'image_url', image_url = { url = 'data:image/png;base64,aGVsbG8=', detail = 'auto' } }
local messages = {
  { role = 'user', content = { { type = 'text', text = 'Inspect this' }, image } },
  { role = 'assistant', tool_calls = {
    { id = 'a', ['function'] = { name = 'attach_file', arguments = '{}' } },
    { id = 'b', ['function'] = { name = 'attach_file', arguments = '{}' } },
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
local reference = require('codeit.attachments').reference(messages)
assert(not vim.json.encode(reference):find('base64', 1, true))
assert(reference[1].content[1].text == 'Inspect this')
assert(reference[1].content[2].text:find('Attachment content omitted', 1, true))
assert(vim.json.encode(messages) == before, 'text references must not alter native image history')
local pdf = { type = 'file', file = { filename = 'report.pdf', file_data = 'data:application/pdf;base64,JVBERi0=' } }
local audio = { type = 'input_audio', input_audio = { format = 'mp3', data = 'SUQz' } }
local mixed = {
  { role = 'user', content = { { type = 'text', text = 'Review files' }, image, pdf, audio } },
  { role = 'assistant', tool_calls = { { id = 'files', ['function'] = { name = 'attach_file', arguments = '{}' } } } },
  { role = 'tool', tool_call_id = 'files', content = { { type = 'text', text = 'Attached files' }, pdf, audio } },
}
local native = chat.body('multimodal', mixed).messages
assert(native[1].content[3].file.filename == 'report.pdf')
assert(native[1].content[4].input_audio.data == 'SUQz')
assert(native[3].role == 'tool' and native[3].content == 'Attached files')
assert(native[4].content[2].type == 'file' and native[4].content[3].type == 'input_audio')
for _, provider in ipairs({ 'Copilot', 'Codex' }) do
  local failed, error_text = responses.body('multimodal', mixed, nil, provider)
  assert(not failed and error_text:find('does not support native audio', 1, true))
  local pdf_messages = { { role = 'user', content = { pdf } }, mixed[2],
    { role = 'tool', tool_call_id = 'files', content = { { type = 'text', text = 'Attached PDF' }, pdf } } }
  local response = assert(responses.body('multimodal', pdf_messages, nil, provider))
  assert(response.input[1].content[1].type == 'input_file')
  assert(response.input[1].content[1].filename == 'report.pdf')
  assert(response.input[1].content[1].file_data == pdf.file.file_data)
  assert(response.input[3].type == 'function_call_output' and response.input[3].output == 'Attached PDF')
  assert(response.input[4].content[2].type == 'input_file')
end
local omitted = vim.json.encode(require('codeit.attachments').reference(mixed))
assert(not omitted:find('JVBERi0', 1, true) and not omitted:find('SUQz', 1, true))
for _, part in ipairs({ pdf, audio }) do
  local expanded = vim.deepcopy(part)
  if expanded.file then expanded.file.file_data = string.rep('A', 100000)
  else expanded.input_audio.data = string.rep('A', 100000) end
  assert(compaction.tokens({ content = { part } }) == compaction.tokens({ content = { expanded } }))
end
print('native attachment protocol tests passed')
