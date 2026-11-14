vim.opt.runtimepath:prepend(vim.fn.getcwd())
local original = vim.fn.getcwd()
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
vim.cmd.cd(root)
local file = assert(io.open(root .. '/image.png', 'wb'))
file:write('\137PNG\r\n\026\n' .. string.rep('x', 16))
file:close()
vim.fn.writefile({ '%PDF-1.7', '%%EOF' }, 'report.pdf')
vim.fn.writefile({ 'ID3recording' }, 'recording.mp3')
local requests, callbacks = {}, {}
package.loaded['codeit.providers'] = {
  chat = function(_, messages, _, callback)
    requests[#requests + 1] = vim.deepcopy(messages)
    callbacks[#callbacks + 1] = callback
  end,
}
local plugin = require('codeit')
plugin.setup({ context_review = false, max_context_tokens = false, approval = {
  tool_call_risk = false, trusted_workspaces = { [root] = 'all' },
} })
local ui = require('codeit.ui')
local draft
ui.peek_input = function() return draft end
ui.take_input = function() draft = nil end
local function command(text)
  draft = text
  plugin.send()
  assert(draft == nil)
end
local function reply(message)
  table.remove(callbacks, 1)(message)
end
command('/attach image.png')
command('/attach report.pdf')
command('/attach recording.mp3')
plugin.send('Describe these attachments')
local function first_user(messages)
  for _, message in ipairs(messages) do
    if message.role == 'user' then return message end
  end
end
assert(first_user(requests[1]).content[3].type == 'image_url')
assert(first_user(requests[1]).content[5].type == 'file')
assert(first_user(requests[1]).content[7].type == 'input_audio')
local names = {}
for _, definition in ipairs(require('codeit.tools').specs) do names[definition['function'].name] = true end
assert(names.attach_file and not names.read_image)
reply({ role = 'assistant', tool_calls = {
  { id = 'image-a', type = 'function', ['function'] = { name = 'attach_file', arguments = '{"path":"image.png","type":"image"}' } },
  { id = 'pdf', type = 'function', ['function'] = { name = 'attach_file', arguments = '{"path":"report.pdf","type":"pdf"}' } },
  { id = 'audio', type = 'function', ['function'] = { name = 'attach_file', arguments = '{"path":"recording.mp3","type":"audio"}' } },
} })
assert(vim.wait(5000, function() return #requests == 2 end))
local outputs = {}
for _, message in ipairs(requests[2]) do
  if message.role == 'tool' then outputs[#outputs + 1] = message end
end
assert(#outputs == 3 and outputs[1].content[2].type == 'image_url')
assert(outputs[2].content[2].type == 'file' and outputs[3].content[2].type == 'input_audio')
local body = require('codeit.providers.protocols.chat').body('vision', requests[2])
assert(body.messages[#body.messages].role == 'user' and #body.messages[#body.messages].content == 6)
reply({ role = 'assistant', content = 'The images match.' })
local history = require('codeit.chat.storage')
local saved = history.list(history.workspace())[1]
assert(saved.messages[2].content[3].type == 'image_url')
assert(saved.messages[4].content[2].image_url.url:match('^data:image/png;base64,'))

command('/attach image.png')
plugin.new()
plugin.send('New chat')
assert(first_user(requests[3]).content == 'New chat', 'new chats must drop queued attachments')
reply({ role = 'assistant', content = 'Ready' })
command('/attach image.png')
plugin.clear()
plugin.send('Cleared chat')
assert(first_user(requests[4]).content == 'Cleared chat', 'clear must drop queued attachments')
reply({ role = 'assistant', content = 'Ready' })
command('/attach image.png')
assert(plugin.resume(saved.id))
plugin.send('Resumed chat')
assert(requests[5][#requests[5]].content == 'Resumed chat', 'resume must drop unsent attachments')
assert(first_user(requests[5]).content[3].type == 'image_url', 'resume must preserve sent images')
reply({ role = 'assistant', content = 'Ready' })
vim.cmd.cd(original)
vim.fn.delete(root, 'rf')
print('native attachment integration tests passed')
