vim.opt.runtimepath:prepend(vim.fn.getcwd())
local root, dir = vim.fn.getcwd(), vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
vim.cmd.cd(dir)
local requests, callbacks = {}, {}
package.loaded['codeit.providers'] = { chat = function(_, messages, specs, cb)
  requests[#requests + 1] = { messages = vim.deepcopy(messages), specs = specs }
  callbacks[#callbacks + 1] = cb
end }
local plugin = require('codeit')
plugin.setup({ max_context_tokens = false })
local prompt = require('codeit.approval_prompt')
prompt.show = function(_, _, cb) cb('once') end
local pending
vim.ui.input = function(_, cb) pending = cb end
local function tool(name, args)
  table.remove(callbacks, 1)({ role = 'assistant', tool_calls = { {
    id = name, type = 'function', ['function'] = { name = name, arguments = vim.json.encode(args) },
  } } })
end
local function finish() table.remove(callbacks, 1)({ role = 'assistant', content = 'done' }) end
local function last() return requests[#requests].messages end
plugin.send('Clarify this task')
local names = {}
for _, spec in ipairs(requests[1].specs) do names[spec['function'].name] = true end
assert(names.ask_user and names.save_buffer)
tool('ask_user', { question = 'Which approach?' })
assert(pending and #callbacks == 0, 'question must pause without a reviewer request')
pending('Use the simpler approach')
assert(#callbacks == 1 and last()[#last()].role == 'tool')
assert(last()[#last()].content:find('Use the simpler approach', 1, true))
finish()
plugin.send('Clarify before executing the rest of a batch')
table.remove(callbacks, 1)({ role = 'assistant', tool_calls = {
  { id = 'question', type = 'function', ['function'] = { name = 'ask_user', arguments = '{"question":"Which approach?"}' } },
  { id = 'later', type = 'function', ['function'] = { name = 'create_file', arguments = '{"path":"must-not-run","content":"no"}' } },
} })
pending('Do not run that command')
assert(last()[#last()].tool_call_id == 'later' and last()[#last()].content:find('Deferred:', 1, true))
assert(vim.fn.filereadable('must-not-run') == 0)
finish()
plugin.send('Ask again')
tool('ask_user', { question = 'Which approach?' })
pending(nil)
assert(#callbacks == 0, 'dismissal must cancel rather than continue')
plugin.send('Continue after cancellation')
local question_batches = 0
for _, message in ipairs(last()) do
  if message.tool_calls then
    for _, call in ipairs(message.tool_calls) do
      if call['function'].name == 'ask_user' then question_batches = question_batches + 1 end
    end
  end
end
assert(question_batches == 2, 'only the earlier answered questions remain after cancellation')
assert(last()[#last()].content == 'Continue after cancellation')
finish()
plugin.send('Ask then reset')
tool('ask_user', { question = 'Which approach?' })
plugin.new()
pending('late answer')
assert(#callbacks == 0)

-- Normal save approval is not an advisory reviewer request or an implicit save.
vim.fn.writefile({ 'before' }, 'save.txt')
local id = vim.fn.bufadd(dir .. '/save.txt')
vim.fn.bufload(id)
vim.api.nvim_buf_set_lines(id, 0, -1, false, { 'unsaved user change' })
require('codeit.write_approval').show = function(diff, _, cb)
  assert(diff.warning and diff.before == 'before\n' and diff.after == 'unsaved user change\n')
  pending = cb
end
plugin.send('Save this named buffer')
tool('save_buffer', { buffer_id = id })
assert(#callbacks == 0 and vim.fn.readfile('save.txt')[1] == 'before')
pending('once')
assert(vim.fn.readfile('save.txt')[1] == 'unsaved user change')
assert(last()[#last()].content:find('Saved ALL', 1, true))
finish()
vim.cmd.cd(root)
vim.fn.delete(dir, 'rf')
print('codeit user interaction tool tests passed')
