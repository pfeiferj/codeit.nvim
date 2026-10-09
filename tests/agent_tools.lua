vim.opt.runtimepath:prepend(vim.fn.getcwd())
local prompt_ui = require('codeit.approval_prompt')
local write_ui = require('codeit.write_approval')
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
  vim.ui.input = function(_, callback) callback(nil) end
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
has(run('create_file', { path = 'sub/demo.txt', content = 'alpha\nbeta\n' }), 'Created')
has(run('create_file', { path = 'sub/demo.txt', content = '' }), 'already exists')
local read = vim.json.decode(run('read_file', { path = 'sub/demo.txt' }))
assert(read.lines[1] == 'alpha' and read.lines[2] == 'beta')
local many = {}
for i = 1, 260 do many[i] = string.format('%03d %s', i, string.rep('x', 90)) end
vim.fn.writefile(many, 'sub/large.txt')
local full = vim.json.decode(run('read_file', { path = 'sub/large.txt' }))
assert(#full.lines == 260 and full.lines[260] == many[260] and full.end_line == 260 and not full.truncated,
  'default read must include the whole file even past 200 lines and 20KB')
local extended = vim.json.decode(run('read_file', { path = 'sub/large.txt', start_line = 250, end_line = 500 }))
assert(#extended.lines == 11 and extended.lines[1] == many[250] and extended.end_line == 260
  and not extended.truncated, 'end_line past EOF should return available lines')
local beyond = vim.json.decode(run('read_file', { path = 'sub/large.txt', start_line = 300, end_line = 500 }))
assert(#beyond.lines == 0 and beyond.end_line == 299 and not beyond.truncated)
has(run('read_file', { path = 'sub/large.txt', start_line = 5, end_line = 4 }), 'invalid range')
has(run('read_file', { path = '../outside' }), 'outside the workspace')
has(run('edit_file', { path = 'sub/demo.txt', old_text = 'alpha', new_text = 'gamma' }, 'reject'), 'Rejected')
assert(preview and preview.before == 'alpha\nbeta\n' and preview.after == 'gamma\nbeta\n',
  'edit preview must contain the whole file, not just the replaced text')
assert(vim.json.decode(run('read_file', { path = 'sub/demo.txt' })).lines[1] == 'alpha')
has(run('edit_file', { path = 'sub/demo.txt', old_text = 'alpha', new_text = 'gamma' }), 'not saved')
assert(vim.json.decode(run('read_file', { path = 'sub/demo.txt' })).lines[1] == 'gamma')
assert(vim.fn.readfile('sub/demo.txt')[1] == 'alpha', 'edits should remain unsaved')
local edited = vim.fn.bufnr(dir .. '/sub/demo.txt')
vim.bo[edited].endofline = false
has(run('edit_file', { path = 'sub/demo.txt', old_text = 'gamma', new_text = 'delta' }, 'reject'), 'Rejected')
assert(preview.before == 'gamma\nbeta' and preview.after == 'delta\nbeta')
vim.bo[edited].endofline = true
has(run('edit_file', { path = 'sub/demo.txt', old_text = 'missing', new_text = 'x' }), 'not found')
local list = vim.json.decode(run('list_workspace_files', { query = 'demo' }))
assert(vim.tbl_contains(list, 'sub/demo.txt'))
has(run('search_workspace', { query = 'alpha' }), 'sub/demo.txt:1:alpha')
local id = vim.fn.bufnr(dir .. '/sub/demo.txt')
local namespace = vim.api.nvim_create_namespace('codeit-test')
vim.diagnostic.set(namespace, id, { { lnum = 0, col = 1, message = 'example warning', severity = vim.diagnostic.severity.WARN } })
has(run('get_diagnostics', { path = 'sub/demo.txt' }), 'example warning')
vim.diagnostic.reset(namespace, id)
local pending
write_ui.show = function(_, _, callback) pending = callback end
local result
local active = true
tools.execute('edit_file', { path = 'sub/demo.txt', old_text = 'gamma', new_text = 'bad' }, nil,
  function(value) result = value end, function() return active end)
vim.api.nvim_buf_set_lines(id, 0, 1, false, { 'manual' })
pending('once')
has(result, 'changed while awaiting confirmation')
assert(vim.api.nvim_buf_get_lines(id, 0, 1, false)[1] == 'manual')
result = nil
active = true
tools.execute('edit_file', { path = 'sub/demo.txt', old_text = 'manual', new_text = 'bad' }, nil,
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
vim.cmd.cd(root)
vim.fn.delete(dir, 'rf')
print('codeit agent tool tests passed')
