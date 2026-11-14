vim.opt.runtimepath:prepend(vim.fn.getcwd())
local ui = require('codeit.ui')
local draft, error_text
ui.peek_input = function() return draft end
ui.take_input = function() draft = nil end
ui.slash_error = function(err) error_text = err end
local session = require('codeit.chat.state').new({})
local api, sent = {}, {}
require('codeit.chat.input').attach(api, session, {
  sync_workspace = function() end,
  set_status = function(status) session.status = status end,
  current_prompt = function() return 'system prompt' end,
  save = function() end,
  render = function() end,
  request = function() sent[#sent + 1] = vim.deepcopy(session.messages) end,
})
local original = vim.fn.getcwd()
local directory = vim.fn.tempname()
vim.fn.mkdir(directory, 'p')
vim.cmd.cd(vim.fn.fnameescape(directory))
local path = directory .. '/screen shot.png'
local file = assert(io.open(path, 'wb'))
file:write(vim.base64.decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII='))
file:close()
local function submit(text)
  draft, error_text = text, nil
  api.send()
end
submit('/image missing.png')
assert(error_text and draft and #session.pending_images == 0)
submit('/image screen shot.png')
assert(not error_text and not draft and #session.pending_images == 1 and #sent == 0)
submit('/image ' .. path)
assert(#session.pending_images == 2 and #sent == 0)
assert(session.status:find('2 image', 1, true))
submit('Compare these images')
assert(#sent == 1 and #session.pending_images == 0)
local content = sent[1][2].content
assert(#content == 5 and content[1].text == 'Compare these images')
assert(content[3].type == 'image_url' and content[5].type == 'image_url')
assert(content[3].image_url.url:match('^data:image/png;base64,'))
submit('/image ' .. path)
assert(error_text and #session.pending_images == 0 and draft)
session.busy = false
submit('Next message')
assert(sent[2][3].content == 'Next message', 'attachments must not be repeated on the next turn')
session.busy = false
submit('/image ' .. path)
submit('/image-clear')
assert(#session.pending_images == 0 and not draft)
submit('/image ' .. path)
vim.api.nvim_create_user_command('CodeitSend', function(opts) api.send(opts.args) end, { nargs = '+' })
submit('/send Describe it')
assert(sent[3][4].content[1].text == 'Describe it' and #session.pending_images == 0)
local second = require('codeit.chat.state').new({})
assert(#second.pending_images == 0)
vim.cmd.cd(vim.fn.fnameescape(original))
vim.fn.delete(directory, 'rf')
print('image_attachments_test: passed')
