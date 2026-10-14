vim.opt.runtimepath:prepend(vim.fn.getcwd())
local prompt_ui = require('codeit.tools.approval.prompt')
local write_ui = require('codeit.tools.approval.write')
local tools = require('codeit.tools')
local root = vim.fn.getcwd()
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
vim.fn.mkdir(dir .. '/sub')
vim.cmd.cd(dir)
local preview
local function run(name, args, choice)
  local result
  prompt_ui.show = function(_, _, callback) callback(choice or 'once') end
  write_ui.show = function(diff, _, callback)
    preview = diff
    callback(choice or 'once')
  end
  require('codeit.ui.input').show = function(config, callback)
    callback(config.prompt:find('Type approve ', 1, true) and ('approve ' .. name) or nil)
  end
  tools.execute(name, args, nil, function(value) result = value end, function() return true end)
  assert(vim.wait(5000, function() return result ~= nil end), 'timed out: ' .. name)
  return result
end
local function has(text, piece)
  assert(text:find(piece, 1, true), text .. ' did not contain ' .. piece)
end
has(run('create_file', { path = 'sub/demo.txt', content = 'alpha\nbeta\n' }, 'reject'), 'Rejected')
assert(preview and preview.before == '' and preview.after == 'alpha\nbeta\n' and preview.path == dir .. '/sub/demo.txt')
assert(vim.fn.filereadable('sub/demo.txt') == 0)
local unwritten = vim.fn.bufadd(dir .. '/sub/unwritten.txt')
vim.fn.bufload(unwritten)
vim.api.nvim_buf_set_lines(unwritten, 0, -1, false, { 'my draft' })
has(run('create_file', { path = 'sub/unwritten.txt', content = 'agent content' }), 'existing unwritten')
assert(vim.fn.filereadable('sub/unwritten.txt') == 0 and vim.bo[unwritten].modified,
  'create_file must not write over an unsaved new-file buffer')
has(run('create_file', { path = 'sub/demo.txt', content = 'alpha\nbeta\n' }), 'Created')
has(run('create_file', { path = 'sub/demo.txt', content = '' }), 'already exists')
local read = vim.json.decode(run('read_file', { path = 'sub/demo.txt' }))
assert(read.lines[1] == 'alpha' and read.lines[2] == 'beta')
assert(vim.deep_equal(read.line_numbers, { 1, 2 }))
local many = {}
-- Leave room for both encoded text and the parallel line-number array.
for i = 1, 260 do many[i] = string.format('%03d %s', i, string.rep('x', 80)) end
vim.fn.writefile(many, 'sub/large.txt')
local full = vim.json.decode(run('read_file', { path = 'sub/large.txt' }))
assert(#full.lines == 200 and full.end_line == 200 and full.truncated and full.total_lines == 260
  and full.next_start_line == 201, 'default reads must be bounded and advertise continuation')
local rest = vim.json.decode(run('read_file', { path = 'sub/large.txt', start_line = full.next_start_line }))
assert(#rest.lines == 60 and rest.lines[60] == many[260] and not rest.truncated)
local extended = vim.json.decode(run('read_file', { path = 'sub/large.txt', start_line = 250, end_line = 500 }))
assert(#extended.lines == 11 and extended.lines[1] == many[250] and extended.end_line == 260
  and not extended.truncated, 'end_line past EOF should return available lines')
assert(extended.line_numbers[1] == 250 and extended.line_numbers[11] == 260)
local beyond = vim.json.decode(run('read_file', { path = 'sub/large.txt', start_line = 300, end_line = 500 }))
assert(#beyond.lines == 0 and beyond.end_line == 299 and not beyond.truncated)
has(run('read_file', { path = 'sub/large.txt', start_line = 5, end_line = 4 }), 'invalid range')
has(run('read_file', { path = '../outside' }), 'outside the workspace')
has(run('edit_file', { path = 'sub/demo.txt', edits = { { old_text = 'alpha', new_text = 'gamma' } } }, 'reject'), 'Rejected')
assert(preview and preview.before == 'alpha\nbeta\n' and preview.after == 'gamma\nbeta\n',
  'edit preview must contain the whole file, not just the replaced text')
assert(vim.json.decode(run('read_file', { path = 'sub/demo.txt' })).lines[1] == 'alpha')
vim.bo[vim.fn.bufnr(dir .. '/sub/demo.txt')].modified = true -- Simulate a pre-existing unsaved edit.
has(run('edit_file', { path = 'sub/demo.txt', edits = { { old_text = 'alpha', new_text = 'gamma' } } }), 'not saved')
assert(vim.json.decode(run('read_file', { path = 'sub/demo.txt' })).lines[1] == 'gamma')
assert(vim.fn.readfile('sub/demo.txt')[1] == 'alpha', 'edits should remain unsaved')
local edited = vim.fn.bufnr(dir .. '/sub/demo.txt')
vim.bo[edited].endofline = false
has(run('edit_file', { path = 'sub/demo.txt', edits = { { old_text = 'gamma', new_text = 'delta' } } }, 'reject'), 'Rejected')
assert(preview.before == 'gamma\nbeta' and preview.after == 'delta\nbeta')
vim.bo[edited].endofline = true
has(run('edit_file', { path = 'sub/demo.txt', edits = { { old_text = 'missing', new_text = 'x' } } }), 'not found')
local mismatch = run('edit_file', { path = 'sub/demo.txt', edits = {
  { old_text = 'gamma', new_text = 'wrong', start_line = 2, end_line = 2 },
} })
has(mismatch, 'in original lines 2-2')
has(mismatch, 'globally unique at line 1')
has(mismatch, 'omit both range bounds')
assert(vim.api.nvim_buf_get_lines(edited, 0, 1, false)[1] == 'gamma', 'must not match outside explicit ranges')
vim.fn.writefile({ 'old', 'keep' }, 'sub/clean.txt')
local clean = vim.fn.bufadd(dir .. '/sub/clean.txt')
vim.fn.bufload(clean)
assert(not vim.bo[clean].modified)
has(run('edit_file', { path = 'sub/clean.txt', edits = { { old_text = 'old', new_text = 'new' } } }), 'saved file')
assert(vim.fn.readfile('sub/clean.txt')[1] == 'new' and not vim.bo[clean].modified,
  'edit_file should save clean files and clear their modified flag')
has(run('edit_loaded_buffer', { buffer_id = clean, edits = { { start_line = 2, end_line = 2,
  old_text = 'keep', new_text = 'replaced' } } }), 'saved file')
assert(vim.fn.readfile('sub/clean.txt')[2] == 'replaced' and not vim.bo[clean].modified,
  'edit_file by buffer ID should save clean files')
vim.api.nvim_buf_set_lines(clean, 0, 1, false, { 'unsaved' })
has(run('edit_loaded_buffer', { buffer_id = clean, edits = { { start_line = 2, end_line = 2,
  old_text = 'replaced', new_text = 'also unsaved' } } }), 'not saved')
assert(vim.fn.readfile('sub/clean.txt')[1] == 'new' and vim.fn.readfile('sub/clean.txt')[2] == 'replaced')
assert(vim.bo[clean].modified and vim.api.nvim_buf_get_lines(clean, 0, 2, false)[2] == 'also unsaved',
  'existing unwritten changes must never be saved by a write tool')
vim.api.nvim_buf_set_lines(clean, 0, 2, false, { 'new', 'replaced' })
vim.bo[clean].modified = false
vim.bo[clean].readonly = true
has(run('edit_file', { path = 'sub/clean.txt', edits = { { old_text = 'new', new_text = 'blocked' } } }),
  'could not save file')
assert(vim.fn.readfile('sub/clean.txt')[1] == 'new' and vim.bo[clean].modified,
  'failed saves must report an error and leave the edit available in the buffer')
vim.bo[clean].readonly = false
local list = vim.json.decode(run('list_workspace_files', { query = 'demo' }))
assert(vim.tbl_contains(list.files, 'sub/demo.txt') and not list.truncated)
local search = run('search_workspace', { query = 'alpha' })
has(search, 'sub/demo.txt:1:alpha')
assert(run('search_workspace', { query = 'alpha', glob = '' }) == search)
for _, glob in ipairs({ '!', '{*.txt,*.lua}', '*\n*' }) do
  has(run('search_workspace', { query = 'alpha', glob = glob }), 'Error: glob')
end
local id = vim.fn.bufnr(dir .. '/sub/demo.txt')
local namespace = vim.api.nvim_create_namespace('codeit-test')
vim.diagnostic.set(namespace, id, { { lnum = 0, col = 1, message = 'example warning', severity = vim.diagnostic.severity.WARN } })
local second = vim.fn.bufnr(dir .. '/sub/large.txt')
vim.diagnostic.set(namespace, second, { { lnum = 1, col = 0, message = 'another workspace warning', severity = vim.diagnostic.severity.WARN } })
local external = vim.fn.tempname()
vim.fn.writefile({ 'outside' }, external)
local external_id = vim.fn.bufadd(external)
vim.fn.bufload(external_id)
vim.diagnostic.set(namespace, external_id, { { lnum = 0, col = 0, message = 'outside warning' } })
local filtered = vim.json.decode(run('get_diagnostics', { path = 'sub/demo.txt' }))
assert(#filtered == 1 and filtered[1].message == 'example warning' and filtered[1].path == dir .. '/sub/demo.txt')
local workspace = vim.json.decode(run('get_diagnostics', { path = '' }))
assert(#workspace == 2, 'empty path should collect loaded workspace diagnostics only')
assert(vim.deep_equal(workspace, vim.json.decode(run('get_diagnostics', {}))),
  'empty path should behave like an omitted path')
assert(vim.tbl_contains(vim.tbl_map(function(item) return item.message end, workspace), 'another workspace warning'))
has(run('get_diagnostics', { path = 'sub/missing.txt' }), 'File does not exist')
vim.diagnostic.reset(namespace)
vim.api.nvim_buf_delete(external_id, { force = true })
vim.fn.delete(external)
local pending
write_ui.show = function(_, _, callback) pending = callback end
local result
local active = true
tools.execute('edit_file', { path = 'sub/demo.txt', edits = { { old_text = 'gamma', new_text = 'bad' } } }, nil,
  function(value) result = value end, function() return active end)
vim.api.nvim_buf_set_lines(id, 0, 1, false, { 'manual' })
pending('once')
has(result, 'changed while awaiting confirmation')
assert(vim.api.nvim_buf_get_lines(id, 0, 1, false)[1] == 'manual')
result = nil
active = true
tools.execute('edit_file', { path = 'sub/demo.txt', edits = { { old_text = 'manual', new_text = 'bad' } } }, nil,
  function(value) result = value end, function() return active end)
active = false
pending('once')
assert(result == nil and vim.api.nvim_buf_get_lines(id, 0, 1, false)[1] == 'manual')
local side_effect = dir .. '/executed'
has(run('run_command', { argv = { 'touch', side_effect } }, 'reject'), 'Rejected')
assert(vim.fn.filereadable(side_effect) == 0)
has(run('run_command', { argv = { 'touch', side_effect } }), '[exit code: 0]')
assert(vim.fn.filereadable(side_effect) == 1)
assert(run('fetch_url', { url = 'file:///etc/passwd' }):find('Error:', 1, true))
local outside = vim.fn.tempname()
vim.fn.writefile({ 'secret' }, outside)
vim.uv.fs_symlink(outside, dir .. '/sub/link')
has(run('read_file', { path = 'sub/link' }), 'outside the workspace')
has(run('create_file', { path = 'sub/link', content = 'x' }), 'outside the workspace')
vim.fn.delete(outside)
vim.fn.system({ 'git', 'init', '-q', dir })
has(run('git_status', {}), 'sub/demo.txt')
vim.fn.writefile({ 'tracked' }, 'sub/tracked.txt')
vim.fn.system({ 'git', 'add', 'sub/tracked.txt' })
vim.fn.writefile({ 'changed' }, 'sub/tracked.txt')
local all_diff = run('git_diff', {})
has(all_diff, 'sub/tracked.txt')
assert(run('git_diff', { path = '' }) == all_diff, 'empty path should return the workspace diff')
assert(run('git_diff', { path = 'sub/tracked.txt' }) == all_diff, 'explicit file path should still work')
has(run('git_diff', { path = '../outside' }), 'outside the workspace')
vim.cmd.cd(root)
vim.fn.delete(dir, 'rf')
print('codeit agent tool tests passed')
