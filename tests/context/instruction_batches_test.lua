vim.opt.runtimepath:prepend(vim.fn.getcwd())
local root, dir = vim.fn.getcwd(), vim.fn.tempname()
vim.fn.mkdir(dir .. '/src', 'p')
vim.fn.writefile({ 'Do not edit generated code.' }, dir .. '/src/AGENTS.md')
vim.fn.writefile({ 'before' }, dir .. '/src/main.txt')
vim.cmd.cd(dir)
local requests, callbacks = {}, {}
package.loaded['codeit.providers'] = { chat = function(_, messages, _, callback)
  requests[#requests + 1] = vim.deepcopy(messages)
  callbacks[#callbacks + 1] = callback
end }
local plugin = require('codeit')
local writes = 0
require('codeit.tools.approval.write').show = function(_, _, cb) writes = writes + 1; cb('once') end
plugin.setup({ max_context_tokens = false, approval = { trusted_workspaces = { [dir] = 'all' } } })
local function call(id, name, args)
  return { id = id, type = 'function', ['function'] = { name = name, arguments = vim.json.encode(args) } }
end
local function reply(calls)
  table.remove(callbacks, 1)({ role = 'assistant', tool_calls = calls })
end
local function finish() table.remove(callbacks, 1)({ role = 'assistant', content = 'Done' }) end
local function last() return requests[#requests] end
plugin.send('Read and consider editing src/main.txt')
assert(not vim.json.encode(last()):find('generated code', 1, true))
reply({ call('read', 'read_file', { path = 'src/main.txt' }),
  call('edit', 'edit_file', { path = 'src/main.txt', edits = { { old_text = 'before', new_text = 'after' } } }) })
assert(writes == 0 and vim.fn.readfile('src/main.txt')[1] == 'before')
assert(vim.json.encode(last()):find('generated code', 1, true))
assert(last()[#last()].tool_call_id == 'edit' and last()[#last()].content:find('Deferred:', 1, true))
finish()
plugin.send('After reviewing instructions, read and edit')
reply({ call('read-again', 'read_file', { path = 'src/main.txt' }),
  call('approved-edit', 'edit_file', { path = 'src/main.txt', edits = { { old_text = 'before', new_text = 'after' } } }) })
assert(writes == 1 and vim.fn.readfile('src/main.txt')[1] == 'after')
assert(last()[#last()].tool_call_id == 'approved-edit' and last()[#last()].content:find('saved file', 1, true))
finish()

-- A first write/create without a prior access also activates instructions before mutation.
plugin.new()
plugin.send('Create a nested file')
reply({ call('create', 'create_file', { path = 'src/new.txt', content = 'new' }) })
assert(writes == 1 and vim.fn.filereadable('src/new.txt') == 0)
assert(vim.json.encode(last()):find('generated code', 1, true))
assert(last()[#last()].content:find('new project instructions', 1, true))
finish()
plugin.send('Create after reviewing the instructions')
reply({ call('create-again', 'create_file', { path = 'src/new.txt', content = 'new' }) })
assert(writes == 2 and vim.fn.readfile('src/new.txt')[1] == 'new')
finish()

-- Invalid arguments and unexpected API failures keep tool histories balanced/recoverable.
plugin.send('Read a buffer')
reply({ call('invalid', 'read_loaded_buffer', { buffer_id = 1.5, start_line = 'bad' }) })
assert(last()[#last()].tool_call_id == 'invalid' and last()[#last()].content:match('^Error:'))
finish()
plugin.send('Retry a read')
local get = vim.api.nvim_buf_get_lines
local target = vim.fn.bufnr(dir .. '/src/main.txt')
local count = #requests
vim.api.nvim_buf_get_lines = function(id, ...) if id == target then error('simulated') end; return get(id, ...) end
reply({ call('failure', 'read_file', { path = 'src/main.txt' }) })
assert(#requests == count + 1 and #callbacks == 1, 'tool exceptions must continue to a new provider request')
vim.api.nvim_buf_get_lines = get
assert(last()[#last()].tool_call_id == 'failure' and last()[#last()].content:match('^Error:'))
finish()
plugin.send('Continue normally')
finish()

-- Invalid metadata is rejected before storing an unmatched tool call.
plugin.send('Malformed provider output')
table.remove(callbacks, 1)({ role = 'assistant', tool_calls = { { id = 'bad', ['function'] = {} } } })
plugin.send('Continue after malformed output')
for _, message in ipairs(last()) do
  if message.tool_calls then for _, item in ipairs(message.tool_calls) do assert(item.id ~= 'bad') end end
end
finish()

-- Instructions changed while a response was in flight are not mistaken for advertised context.
plugin.send('Propose a write')
vim.fn.writefile({ 'Updated restrictions.' }, 'src/AGENTS.md')
reply({ call('changed-context', 'edit_file', { path = 'src/main.txt', edits = { { old_text = 'after', new_text = 'bad' } } }) })
assert(writes == 2 and vim.fn.readfile('src/main.txt')[1] == 'after')
assert(last()[#last()].content:find('new project instructions', 1, true))
finish()
plugin.send('Read under updated restrictions')
reply({ call('updated-read', 'read_file', { path = 'src/main.txt' }) })
finish()
local pending
require('codeit.tools.approval.write').show = function(_, _, cb) pending = cb end
plugin.send('Propose a change for approval')
reply({ call('pending-write', 'edit_file', { path = 'src/main.txt', edits = { { old_text = 'after', new_text = 'bad' } } }) })
assert(pending)
vim.fn.writefile({ 'Changed again during approval.' }, 'src/AGENTS.md')
pending('once')
assert(vim.fn.readfile('src/main.txt')[1] == 'after')
assert(last()[#last()].content:find('project instructions changed while awaiting approval', 1, true))
finish()

-- Unified buffer-ID reads activate nested instructions just like path reads.
plugin.new()
plugin.send('Read this loaded buffer and consider an edit')
assert(not vim.json.encode(last()):find('Changed again during approval.', 1, true))
reply({ call('buffer-read', 'read_loaded_buffer', { buffer_id = target }),
  call('buffer-edit', 'edit_loaded_buffer', { buffer_id = target, edits = { { old_text = 'after', new_text = 'bad' } } }) })
assert(vim.json.encode(last()):find('Changed again during approval.', 1, true))
assert(last()[#last()].tool_call_id == 'buffer-edit' and last()[#last()].content:find('Deferred:', 1, true))
assert(vim.fn.readfile('src/main.txt')[1] == 'after')
finish()
vim.cmd.cd(root)
vim.fn.delete(dir, 'rf')
print('codeit instruction batch tests passed')
