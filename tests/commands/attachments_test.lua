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
local slash = require('codeit.commands.slash')
assert(slash.parse('/image screen.png') == false and slash.parse('/imageClear') == false)
assert(slash.parse('/attach report.pdf').name == 'attach')
assert(slash.validate(slash.parse('/attach'), ''))
vim.fn.writefile({ '%PDF-1.7', '%%EOF' }, 'report.pdf')
vim.fn.writefile({ 'RIFF1234WAVEdata' }, 'recording.wav')
submit('/attach missing.png')
assert(error_text and draft and #session.pending_attachments == 0)
submit('/attach screen shot.png')
assert(not error_text and not draft and #session.pending_attachments == 1 and #sent == 0)
submit('/attach report.pdf')
submit('/attach recording.wav')
assert(#session.pending_attachments == 3 and #sent == 0)
assert(session.status:find('3 attachment', 1, true))
submit('Compare these files')
assert(#sent == 1 and #session.pending_attachments == 0)
local content = sent[1][2].content
assert(#content == 7 and content[1].text == 'Compare these files')
assert(content[3].type == 'image_url' and content[5].type == 'file' and content[7].type == 'input_audio')
assert(content[5].file.filename == 'report.pdf' and content[7].input_audio.format == 'wav')
assert(content[3].image_url.url:match('^data:image/png;base64,'))
submit('/attach ' .. path)
assert(error_text and #session.pending_attachments == 0 and draft)
session.busy = false
submit('Next message')
assert(sent[2][3].content == 'Next message', 'attachments must not be repeated on the next turn')
session.busy = false
submit('/attach ' .. path)
submit('/attach-clear')
assert(#session.pending_attachments == 0 and not draft)
submit('/attach ' .. path)
vim.api.nvim_create_user_command('CodeitSend', function(opts) api.send(opts.args) end, { nargs = '+' })
submit('/send Describe it')
assert(sent[3][4].content[1].text == 'Describe it' and #session.pending_attachments == 0)
local second = require('codeit.chat.state').new({})
assert(#second.pending_attachments == 0)
vim.cmd.cd(vim.fn.fnameescape(original))
vim.fn.delete(directory, 'rf')
print('attachment command tests passed')
