vim.opt.runtimepath:prepend(vim.fn.getcwd())
local root, dir, other = vim.fn.getcwd(), vim.fn.tempname(), vim.fn.tempname()
vim.fn.mkdir(dir .. '/src', 'p')
vim.fn.mkdir(dir .. '/docs', 'p')
vim.fn.mkdir(other, 'p')
vim.cmd.cd(dir)
local tools = require('codeit.tools')
local approval = require('codeit.approval')
local prompt = require('codeit.approval_prompt')
local writes = require('codeit.write_approval')
local preview, approvals, choice = nil, 0, 'once'
vim.ui.input = function(_, cb) cb(nil) end
prompt.show = function(_, _, cb) cb(choice) end
writes.show = function(diff, _, cb) preview = diff; approvals = approvals + 1; cb(choice) end
local function run(name, args, source, context)
  local result, signal
  tools.execute(name, args, source, function(value, kind) result, signal = value, kind end, function() return true end, context)
  assert(vim.wait(6000, function() return result ~= nil end), name)
  return result, signal
end
local function decode(text) return vim.json.decode(text) end
local function has(text, expected) assert(text:find(expected, 1, true), text) end
local function content(id) return table.concat(vim.api.nvim_buf_get_lines(id, 0, -1, false), '\n') end
local function loaded(path) local id = vim.fn.bufadd(path); vim.fn.bufload(id); return id end

-- Atomic edits are matched against one original revision, independent of order.
vim.fn.writefile({ 'alpha', 'beta', 'repeat', 'repeat', 'omega' }, 'src/edit.txt')
local ctx = { read_versions = {} }
local read = decode(run('read_file', { path = 'src/edit.txt' }, nil, ctx))
local batch = { { old_text = 'omega', new_text = 'last\nextra' },
  { old_text = 'alpha', new_text = 'beta' }, { old_text = 'beta', new_text = 'second' },
  { old_text = 'repeat', new_text = 'unique', start_line = 4, end_line = 4 } }
local count = approvals
has(run('edit_file', { path = 'src/edit.txt', edits = batch }, nil, ctx), 'saved file')
assert(approvals == count + 1 and content(read.buffer_id) == 'beta\nsecond\nrepeat\nunique\nlast\nextra')
assert(preview.before == 'alpha\nbeta\nrepeat\nrepeat\nomega\n')
assert(preview.after == content(read.buffer_id) .. '\n')
local original = content(read.buffer_id)
for _, invalid in ipairs({
  { { old_text = 'second', new_text = 'ok' }, { old_text = 'missing', new_text = 'no' } },
  { { old_text = 'second', new_text = 'ok' }, { old_text = 'second\nrepeat', new_text = 'overlap' } },
  { { old_text = 'beta', new_text = 'ok' }, { old_text = 'beta', new_text = 'duplicate' } },
  { { old_text = 'second', new_text = 'ok' }, { old_text = 'last', new_text = 'no', start_line = 99, end_line = 99 } },
}) do
  count = approvals
  has(run('edit_loaded_buffer', { buffer_id = read.buffer_id, edits = invalid }, nil, ctx), 'Error:')
  assert(content(read.buffer_id) == original and approvals == count, 'invalid batches must not mutate or prompt')
end
has(run('edit_loaded_buffer', { buffer_id = read.buffer_id, edits = {}, old_text = 'beta', new_text = 'bad' }), 'Error:')
has(run('edit_loaded_buffer', { buffer_id = read.buffer_id, edits = { { old_text = 'beta' } } }), 'Error:')
has(run('edit_loaded_buffer', { buffer_id = read.buffer_id, edits = { { old_text = 'beta', new_text = 'x', extra = 1 } } }), 'Error:')
has(run('edit_loaded_buffer', { buffer_id = read.buffer_id, edits = { { old_text = 'beta', new_text = 'x', start_line = 1.5, end_line = 1 } } }), 'Error:')
choice = 'reject'
has(run('edit_loaded_buffer', { buffer_id = read.buffer_id, edits = { { old_text = 'beta', new_text = 'bad' } } }, nil, ctx), 'Rejected')
assert(content(read.buffer_id) == original)
choice = 'once'
local pending, result
writes.show = function(diff, _, cb) preview = diff; pending = cb end
tools.execute('edit_loaded_buffer', { buffer_id = read.buffer_id, edits = { { old_text = 'beta', new_text = 'bad' } } }, nil,
  function(value) result = value end, function() return true end, ctx)
vim.api.nvim_buf_set_lines(read.buffer_id, 0, 1, false, { 'user edit' })
pending('once')
has(result, 'changed while awaiting confirmation')
assert(content(read.buffer_id):find('user edit', 1, true))
writes.show = function(_, _, cb) cb('once') end
vim.fn.writefile({ 'one', 'two' }, 'src/fail-save.txt')
local failure_id = loaded(dir .. '/src/fail-save.txt')
vim.bo[failure_id].readonly = true
has(run('edit_loaded_buffer', { buffer_id = failure_id, edits = {
  { old_text = 'one', new_text = 'first' }, { old_text = 'two', new_text = 'second' },
} }), 'could not save file')
assert(content(failure_id) == 'first\nsecond' and vim.bo[failure_id].modified)
assert(vim.deep_equal(vim.fn.readfile('src/fail-save.txt'), { 'one', 'two' }))

-- Saving explicitly includes every unsaved user/agent change and cannot be remembered.
vim.fn.writefile({ 'disk' }, 'src/save.txt')
local id = loaded(dir .. '/src/save.txt')
vim.api.nvim_buf_set_lines(id, 0, -1, false, { 'user change', 'agent change' })
writes.show = function(diff, options, cb)
  preview = diff; approvals = approvals + 1
  assert(diff.warning:find('including the user', 1, true))
  for _, option in ipairs(options) do assert(option.id ~= 'always') end
  cb(choice)
end
approval.setup({ trusted_workspaces = { [dir] = 'all' }, validators = { function() return 'approve' end } })
count = approvals
has(run('save_source_buffer', {}, id), 'Saved ALL')
assert(approvals == count + 1 and not vim.bo[id].modified)
assert(vim.deep_equal(vim.fn.readfile('src/save.txt'), { 'user change', 'agent change' }))
assert(preview.before == 'disk\n' and preview.after == 'user change\nagent change\n')
choice = 'reject'
vim.api.nvim_buf_set_lines(id, 0, 1, false, { 'not approved' })
has(run('save_buffer', { path = 'src/save.txt' }), 'Rejected')
assert(vim.fn.readfile('src/save.txt')[1] == 'user change' and vim.bo[id].modified)
choice = 'once'
vim.bo[id].readonly = true
has(run('save_loaded_buffer', { buffer_id = id }), 'Error: not saved')
assert(vim.bo[id].modified)
vim.bo[id].readonly = false
local unnamed = vim.api.nvim_create_buf(true, false)
has(run('save_source_buffer', {}, unnamed), 'no file name')
local new_id = loaded(dir .. '/src/new.txt')
vim.api.nvim_buf_set_lines(new_id, 0, -1, false, { 'new file draft' })
has(run('save_buffer', { path = 'src/new.txt' }), 'Saved ALL')
assert(vim.fn.readfile('src/new.txt')[1] == 'new file draft')
writes.show = function(_, _, cb) pending = cb end
result = nil
tools.execute('save_loaded_buffer', { buffer_id = id }, nil, function(value) result = value end, function() return true end)
vim.fn.writefile({ 'external changed' }, 'src/save.txt')
pending('once')
has(result, 'changed while awaiting confirmation')
assert(vim.fn.readfile('src/save.txt')[1] == 'external changed')
result = nil
tools.execute('save_loaded_buffer', { buffer_id = new_id }, nil, function(value) result = value end, function() return true end)
vim.api.nvim_buf_set_lines(new_id, 0, -1, false, { 'manual during approval' })
pending('once')
has(result, 'changed while awaiting confirmation')
assert(vim.fn.readfile('src/new.txt')[1] == 'new file draft')
has(run('save_buffer', { path = 'not-loaded.txt' }), 'already-loaded')
has(run('save_buffer', { path = 'src/save.txt', buffer_id = id }), 'unknown argument buffer_id')
has(run('save_loaded_buffer', { buffer_id = id, path = 'src/save.txt' }), 'unknown argument path')
has(run('save_source_buffer', { path = 'src/save.txt' }, id), 'unknown argument path')
has(run('save_buffer', {}), 'missing argument path')
has(run('save_loaded_buffer', {}), 'missing argument buffer_id')
has(run('save_source_buffer', {}), 'no source buffer')
approval.setup({ validators = { function(name) if name == 'save_loaded_buffer' then return 'reject', 'blocked' end end } })
has(run('save_loaded_buffer', { buffer_id = id }), 'Rejected by approval policy')

-- Questions use choices or free text, respect reject validators, and cancel cleanly.
approval.setup({})
local selections, inputs = 0, 0
vim.ui.select = function(items, opts, cb)
  selections = selections + 1; assert(opts.prompt:find('Which', 1, true)); cb(items[2])
end
vim.ui.input = function(_, cb) inputs = inputs + 1; cb('free answer') end
assert(decode(run('ask_user', { question = 'Which approach?', choices = { 'A', 'B' } })).answer == 'B')
vim.ui.select = function(items, _, cb) cb(items[#items]) end
assert(decode(run('ask_user', { question = 'Which approach?', choices = { 'A' } })).answer == 'free answer')
assert(decode(run('ask_user', { question = 'Clarify please' })).answer == 'free answer')
vim.ui.input = function(_, cb) cb(nil) end
local _, signal = run('ask_user', { question = 'Clarify please' })
assert(signal == 'cancel')
vim.ui.select = function(_, _, cb) cb(nil) end
_, signal = run('ask_user', { question = 'Which approach?', choices = { 'A' } })
assert(signal == 'cancel')
has(run('ask_user', { question = '  ' }), 'Error:')
has(run('ask_user', { question = 'question', choices = { 1 } }), 'Error:')
approval.setup({ validators = { function(name) if name == 'ask_user' then return 'reject' end end } })
has(run('ask_user', { question = 'blocked' }), 'Rejected by approval policy')
approval.setup({})
local live = true
vim.ui.input = function(_, cb) pending = cb end
result = nil
tools.execute('ask_user', { question = 'stale' }, nil, function(value) result = value end, function() return live end)
live = false
pending('late answer')
assert(result == nil)

-- Directory/glob filters retain workspace-relative paths and gitignore rules.
vim.system({ 'git', 'init', '-q' }):wait()
prompt.show = function(_, _, cb) cb('once') end
vim.fn.writefile({ 'before', 'needle', 'after' }, 'src/a.lua')
vim.fn.writefile({ 'needle' }, 'src/b.txt')
vim.fn.writefile({ 'needle' }, 'docs/a.lua')
vim.fn.writefile({ 'ignored.lua' }, '.gitignore')
vim.fn.writefile({ 'needle' }, 'src/ignored.lua')
vim.uv.fs_symlink(other, dir .. '/escape')
local listing = decode(run('list_workspace_files', { directory = 'src', query = '.lua' }))
assert(#listing.files == 1 and listing.files[1] == 'src/a.lua')
local search = run('search_workspace', { query = 'needle', directory = 'src', glob = '*.lua', context_lines = 1 })
has(search, './src/a.lua:2:needle')
has(search, './src/a.lua-1-before')
has(search, './src/a.lua-3-after')
assert(not search:find('b.txt', 1, true) and not search:find('docs', 1, true) and not search:find('ignored', 1, true))
has(run('search_workspace', { query = 'needle', directory = '../outside' }), 'Error:')
has(run('list_workspace_files', { directory = 'escape' }), 'Error:')
has(run('search_workspace', { query = 'needle', context_lines = 21 }), 'Error:')
search = run('search_workspace', { query = 'needle', glob = '!*.txt' })
assert(not search:find('b.txt', 1, true) and search:find('docs/a.lua', 1, true))
has(run('search_workspace', { query = 'needle', glob = '*.missing' }), '[exit code: 1]')
vim.fn.writefile({ string.rep('x', 400) .. 'needle' }, 'src/long.lua')
search = run('search_workspace', { query = 'needle', directory = 'src', glob = 'long.lua' })
assert(not search:find(string.rep('x', 400), 1, true))
local matched = {}
for i = 1, 400 do matched[i] = 'needle ' .. string.rep('x', 100) end
vim.fn.writefile(matched, 'src/many.lua')
has(run('search_workspace', { query = 'needle', glob = 'many.lua' }), 'output truncated')

-- Staged and base comparisons never enable external helper execution.
vim.system({ 'git', 'init', '-q' }):wait()
vim.system({ 'git', 'add', 'src/a.lua' }):wait()
assert(vim.system({ 'git', '-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '-qm', 'initial' }):wait().code == 0)
vim.fn.writefile({ 'staged' }, 'src/a.lua')
vim.system({ 'git', 'add', 'src/a.lua' }):wait()
vim.fn.writefile({ 'unstaged' }, 'src/a.lua')
has(run('git_diff', { staged = true, path = 'src/a.lua' }), '+staged')
assert(not run('git_diff', { staged = true }):find('+unstaged', 1, true))
has(run('git_diff', { base = 'HEAD', path = 'src/a.lua' }), '+unstaged')
has(run('git_diff', { staged = true, base = 'HEAD', path = 'src/a.lua' }), '+staged')
has(run('git_diff', { base = '--output=/tmp/bad' }), 'Error:')
has(run('git_diff', { base = 'HEAD..HEAD' }), 'Error:')
has(run('git_diff', { base = 'missing-ref' }), 'Error:')

-- Diagnostics wait only for matching events and describe timeout, not freshness.
local diagnostic_id = loaded(dir .. '/src/a.lua')
local ns = vim.api.nvim_create_namespace('tool-expansion')
vim.defer_fn(function()
  vim.diagnostic.set(ns, diagnostic_id, { { lnum = 0, col = 0, message = 'new warning' } })
end, 30)
local waited = decode(run('get_diagnostics', { path = 'src/a.lua', wait_ms = 500 }))
assert(waited.updated and not waited.timed_out and waited.diagnostics[1].message == 'new warning')
vim.defer_fn(function() vim.diagnostic.set(ns, id, { { lnum = 0, col = 0, message = 'unrelated' } }) end, 10)
waited = decode(run('get_diagnostics', { path = 'src/a.lua', wait_ms = 50 }))
assert(not waited.updated and waited.timed_out and waited.waited_ms >= 50)
assert(type(decode(run('get_diagnostics', { path = 'src/a.lua' }))[1].message) == 'string')
has(run('get_diagnostics', { wait_ms = 5001 }), 'Error:')
local before = #vim.api.nvim_get_autocmds({ event = 'DiagnosticChanged' })
live, result = true, nil
tools.execute('get_diagnostics', { wait_ms = 200 }, nil, function(value) result = value end, function() return live end)
live = false
vim.wait(50, function() return false end)
assert(result == nil and #vim.api.nvim_get_autocmds({ event = 'DiagnosticChanged' }) == before)
vim.diagnostic.reset(ns)
vim.cmd.cd(root)
vim.fn.delete(dir, 'rf')
vim.fn.delete(other, 'rf')
print('codeit expanded tool tests passed')
