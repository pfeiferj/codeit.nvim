vim.opt.runtimepath:prepend(vim.fn.getcwd())
local root, dir = vim.fn.getcwd(), vim.fn.tempname()
vim.fn.mkdir(dir .. '/src', 'p')
vim.cmd.cd(dir)
local tools = require('codeit.tools')
local prompt = require('codeit.approval_prompt')
local write = require('codeit.write_approval')
prompt.show = function(_, _, cb) cb('once') end
write.show = function(_, _, cb) cb('once') end
local function run(name, args, context)
  local result
  tools.execute(name, args, nil, function(value) result = value end, function() return true end, context)
  assert(vim.wait(5000, function() return result ~= nil end), 'timeout: ' .. name)
  return result
end
local function has(value, text) assert(value:find(text, 1, true), value) end

-- Filtering is performed over every filename, with deterministic paginated output.
for i = 1, 260 do
  vim.fn.writefile({ 'x' }, string.format('%03d-%s.txt', i, string.rep('a', 100)))
end
local name = '260-' .. string.rep('a', 100) .. '.txt'
local found = vim.json.decode(run('list_workspace_files', { query = name }))
assert(#found.files == 1 and found.files[1] == name and not found.truncated)
local offset, all = 0, {}
repeat
  local page = vim.json.decode(run('list_workspace_files', { offset = offset }))
  assert(#page.files > 0 and page.total_matches == 260)
  vim.list_extend(all, page.files)
  offset = page.next_offset
until not offset
assert(#all == 260 and all[260] == name)
local system = vim.system
vim.system = function(_, _, callback)
  vim.schedule(function() callback({ code = 2, stdout = '', stderr = '' }) end)
  return { kill = function() end }
end
has(run('list_workspace_files', {}), 'Error: file listing failed')
vim.system = system

-- Refresh even same-sized quick writes; never overwrite an unsaved buffer.
vim.fn.writefile({ 'before' }, 'sample.txt')
assert(vim.json.decode(run('read_file', { path = 'sample.txt' })).lines[1] == 'before')
run('run_command', { argv = { 'sh', '-c', "printf 'after!\\n' > sample.txt" } })
assert(vim.json.decode(run('read_file', { path = 'sample.txt' })).lines[1] == 'after!')
local id = vim.fn.bufnr(dir .. '/sample.txt')
vim.api.nvim_buf_set_lines(id, 0, -1, false, { 'unsaved' })
vim.fn.writefile({ 'external' }, 'sample.txt')
assert(vim.json.decode(run('read_loaded_buffer', { buffer_id = id })).lines[1] == 'unsaved')
local clean = vim.fn.bufadd(dir .. '/new.txt')
vim.fn.bufload(clean)
has(run('create_file', { path = 'new.txt', content = 'created\n' }), 'Created')
assert(vim.json.decode(run('read_file', { path = 'new.txt' })).lines[1] == 'created')

-- Bounded encoded output, explicit continuation and no partial source lines.
local many = {}
for i = 1, 12000 do many[i] = string.rep('x', 100) end
vim.fn.writefile(many, 'large.txt')
local raw = run('read_file', { path = 'large.txt', end_line = 12000 })
local page = vim.json.decode(raw)
assert(#raw < 21000 and #page.lines <= 200 and page.truncated and page.total_lines == 12000)
assert(page.next_start_line == page.end_line + 1)
local tail = vim.json.decode(run('read_file', { path = 'large.txt', start_line = 11999, end_line = 13000 }))
assert(#tail.lines == 2 and not tail.truncated and not tail.next_start_line)
vim.fn.writefile({ string.rep('x', 30000) }, 'long-line.txt')
has(run('read_file', { path = 'long-line.txt' }), 'Line exceeds')

-- Invalid arguments are ordinary errors; deferred approval actions are guarded too.
for _, args in ipairs({ { buffer_id = id, start_line = 'bad' }, { buffer_id = 1.5 },
  { buffer_id = vim.NIL }, { buffer_id = id, end_line = false } }) do
  has(run('read_loaded_buffer', args), 'Error:')
end
has(run('run_command', { argv = { [1] = 'echo', extra = 'x' } }), 'Error:')
has(run('run_command', { argv = { 'echo', '\0' } }), 'Error:')
has(run('run_command', { argv = { 'printf', '<%s>', '' } }), '<>')
local pending, result
prompt.show = function(_, _, cb) pending = cb end
tools.execute('read_loaded_buffer', { buffer_id = clean }, nil, function(value) result = value end,
  function() return true end)
local get = vim.api.nvim_buf_get_lines
vim.api.nvim_buf_get_lines = function() error('simulated API failure') end
pending('once')
vim.api.nvim_buf_get_lines = get
has(result, 'Error: tool execution failed:')
prompt.show = function(_, _, cb) cb('once') end

-- Edits in chat must follow a read of the current revision.
local context = { read_versions = {} }
has(run('edit_file', { path = 'new.txt', old_text = 'created', new_text = 'changed' }, context), 'read the current file')
run('read_file', { path = 'new.txt' }, context)
has(run('edit_file', { path = 'new.txt', old_text = 'created', new_text = 'changed' }, context), 'saved file')
has(run('edit_file', { path = 'new.txt', old_text = 'changed', new_text = 'again' }, context), 'saved file')
run('run_command', { argv = { 'sh', '-c', "printf 'external\\n' > new.txt" } })
has(run('edit_file', { path = 'new.txt', old_text = 'external', new_text = 'bad' }, context), 'read the current file')
run('read_file', { path = 'new.txt' }, context)
write.show = function(_, _, cb) pending = cb end
result = nil
tools.execute('edit_file', { path = 'new.txt', old_text = 'external', new_text = 'bad' }, nil,
  function(value) result = value end, function() return true end, context)
vim.fn.writefile({ 'manual on disk' }, 'new.txt')
pending('once')
has(result, 'changed while awaiting confirmation')
assert(vim.fn.readfile('new.txt')[1] == 'manual on disk')
write.show = function(_, _, cb) cb('once') end

-- Git helpers must not run configured external programs; deleted paths work.
vim.system({ 'git', 'init', '-q' }):wait()
vim.fn.writefile({ 'tracked' }, 'tracked.txt')
vim.system({ 'git', 'add', 'tracked.txt' }):wait()
vim.fn.writefile({ '*.txt diff=demo' }, '.gitattributes')
local script = dir .. '/helper.sh'
vim.fn.writefile({ '#!/bin/sh', 'touch "' .. dir .. '/helper-ran"', 'cat "$1"' }, script)
vim.uv.fs_chmod(script, 493)
vim.system({ 'git', 'config', 'diff.demo.textconv', script }):wait()
vim.system({ 'git', 'config', 'core.fsmonitor', script }):wait()
vim.fn.writefile({ 'changed' }, 'tracked.txt')
run('git_diff', {})
run('git_status', {})
assert(vim.fn.filereadable('helper-ran') == 0)
vim.fn.delete('tracked.txt')
has(run('git_diff', { path = 'tracked.txt' }), 'deleted file')
tools.configure({ trusted_workspaces = { [dir] = 'tracked' } })
local prompts = 0
prompt.show = function(_, _, cb) prompts = prompts + 1; cb('once') end
assert(run('git_diff', {}) == run('git_diff', { path = '' }))
run('git_diff', { path = 'tracked.txt' })
assert(prompts == 0 and vim.fn.filereadable('helper-ran') == 0)
tools.configure({})

-- HTTP status/final URL/body are separate, including non-2xx and truncation.
vim.system = function(argv, opts, cb)
  assert(argv[2] == '--disable')
  assert(vim.tbl_contains(argv, '--proto-redir'))
  local output, status
  for i, arg in ipairs(argv) do
    if arg == '--output' then output = argv[i + 1] end
    if arg == '--url' then status = argv[i + 1]:find('404', 1, true) and '404' or '200' end
  end
  vim.fn.writefile({ status == '404' and 'Not Found' or string.rep('x', 25000) }, output)
  vim.schedule(function()
    opts.stdout(nil, status .. '\nhttp://127.0.0.1/final')
    cb({ code = 0 })
  end)
  return { kill = function() end }
end
local failed = run('fetch_url', { url = 'http://127.0.0.1/404' })
has(failed, 'Error: URL fetch failed')
has(failed, '"http_status":404')
has(failed, 'http://127.0.0.1/final')
local fetched = vim.json.decode(run('fetch_url', { url = 'http://127.0.0.1/ok' }))
assert(fetched.http_status == 200 and fetched.truncated and #fetched.body == 20000)
vim.system = system
vim.cmd.cd(root)
vim.fn.delete(dir, 'rf')
print('codeit tool contract tests passed')
