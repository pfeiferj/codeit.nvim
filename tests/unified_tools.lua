vim.opt.runtimepath:prepend(vim.fn.getcwd())
local root, dir, other = vim.fn.getcwd(), vim.fn.tempname(), vim.fn.tempname()
vim.fn.mkdir(dir .. '/src', 'p')
vim.fn.mkdir(other, 'p')
vim.fn.writefile({ 'workspace' }, dir .. '/src/file.txt')
vim.fn.writefile({ 'external' }, other .. '/file.txt')
vim.cmd.cd(dir)
local tools = require('codeit.tools')
local approval = require('codeit.approval')
local prompt = require('codeit.approval_prompt')
local writes = require('codeit.write_approval')
local files = require('codeit.context_files')
local asked, preview = 0, nil
prompt.show = function(_, _, cb) asked = asked + 1; cb('once') end
writes.show = function(diff, _, cb) preview = diff; cb('once') end
local function run(name, args, source, context)
  local result
  tools.execute(name, args, source, function(value) result = value end, function() return true end, context)
  assert(vim.wait(5000, function() return result ~= nil end), name)
  return result
end
local function has(text, expected) assert(text:find(expected, 1, true), text) end
local function loaded(path)
  local id = vim.fn.bufadd(path)
  vim.fn.bufload(id)
  return id
end
local inside, outside = loaded(dir .. '/src/file.txt'), loaded(other .. '/file.txt')
local unnamed = vim.api.nvim_create_buf(true, false)
local unrelated_unnamed = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(unnamed, 0, -1, false, { 'alpha', 'repeat', 'repeat', 'omega' })
local scratch = vim.api.nvim_create_buf(false, true)
vim.fn.writefile({ 'escaped' }, other .. '/symlink-target.txt')
vim.uv.fs_symlink(other .. '/symlink-target.txt', dir .. '/escape.txt')
local escaped = loaded(dir .. '/escape.txt')
local function ids(text)
  local result = {}
  for _, item in ipairs(vim.json.decode(text)) do result[item.id] = item end
  return result
end
approval.setup({ trusted_workspaces = { [dir] = 'all' } })
local count = asked
local listed = ids(run('list_buffers', {}, inside))
assert(listed[inside] and listed[inside].source and not listed[outside] and not listed[escaped])
assert(not listed[unnamed] and not listed[scratch] and asked == count)
listed = ids(run('list_buffers', {}, unnamed))
assert(listed[inside] and listed[unnamed].name == '' and listed[unnamed].source)
assert(not listed[unrelated_unnamed] and asked == count + 1, 'unnamed source must still require approval')
listed = ids(run('list_buffers', {}, outside))
assert(listed[outside] and listed[outside].source and not listed[escaped])
listed = ids(run('list_buffers', { include_external = true }, inside))
assert(listed[outside] and listed[escaped] and listed[unrelated_unnamed] and not listed[scratch])
assert(asked == count + 3, 'broad listing must require explicit approval even in all mode')
has(run('list_buffers', { include_external = 'yes' }, inside), 'Error:')

-- Read and write tools expose separate schemas for path, loaded buffer and source buffer.
local read_specs = {}
for _, definition in ipairs(tools.request_specs(dir, 'all')) do
  read_specs[definition['function'].name] = definition['function'].parameters
end
assert(read_specs.read_file.properties.path and not read_specs.read_file.properties.buffer_id
  and vim.deep_equal(read_specs.read_file.required, { 'path' }))
assert(read_specs.read_loaded_buffer.properties.buffer_id and not read_specs.read_loaded_buffer.properties.path
  and vim.deep_equal(read_specs.read_loaded_buffer.required, { 'buffer_id' }))
assert(not read_specs.read_source_buffer.properties.path and not read_specs.read_source_buffer.properties.buffer_id)
for _, action in ipairs({ 'edit', 'save' }) do
  local by_path = read_specs[action == 'edit' and 'edit_file' or 'save_buffer']
  local by_id = read_specs[action .. '_loaded_buffer']
  local by_source = read_specs[action .. '_source_buffer']
  assert(by_path.properties.path and not by_path.properties.buffer_id
    and vim.deep_equal(by_path.required, action == 'edit' and { 'path', 'edits' } or { 'path' }))
  assert(by_id.properties.buffer_id and not by_id.properties.path
    and vim.deep_equal(by_id.required, action == 'edit' and { 'buffer_id', 'edits' } or { 'buffer_id' }))
  assert(not by_source.properties.path and not by_source.properties.buffer_id)
  if action == 'edit' then
    for _, schema in ipairs({ by_path, by_id, by_source }) do
      assert(schema.properties.edits and schema.properties.edits.minItems == 1
        and schema.properties.edits.items.additionalProperties == false
        and vim.deep_equal(schema.properties.edits.items.required, { 'old_text', 'new_text' })
        and not schema.properties.old_text and not schema.properties.new_text
        and not schema.properties.start_line and not schema.properties.end_line
        and vim.tbl_contains(schema.required, 'edits'))
    end
  end
end
local context = { read_versions = {} }
has(run('edit_loaded_buffer', { buffer_id = unnamed, edits = { { old_text = 'alpha', new_text = 'bad' } } }, nil, context), 'read the current file')
local read = vim.json.decode(run('read_source_buffer', {}, unnamed, context))
assert(read.path == '' and read.buffer_id == unnamed and #read.lines == 4)
has(run('edit_source_buffer', { edits = { { old_text = 'repeat', new_text = 'changed' } } }, unnamed, context), 'not unique')
has(run('edit_source_buffer', { edits = { { old_text = 'repeat', new_text = 'changed', start_line = 3, end_line = 3 } } }, unnamed, context), 'not saved')
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(unnamed, 0, -1, false), { 'alpha', 'repeat', 'changed', 'omega' }))
assert(preview.path == '' and preview.after:find('alpha\nrepeat\nchanged\nomega', 1, true))
has(run('edit_loaded_buffer', { buffer_id = unnamed, edits = { { old_text = 'alpha\nrepeat', new_text = 'first' } } }, nil, context), 'not saved')
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(unnamed, 0, -1, false), { 'first', 'changed', 'omega' }))
read = vim.json.decode(run('read_file', { path = 'src/file.txt' }, nil, context))
assert(read.buffer_id == inside and read.path == dir .. '/src/file.txt')
has(run('edit_loaded_buffer', { buffer_id = inside, edits = { { old_text = 'workspace', new_text = 'saved' } } }, nil, context), 'saved file')
assert(vim.fn.readfile('src/file.txt')[1] == 'saved')
local new_buffer = loaded(dir .. '/new-unsaved.txt')
vim.api.nvim_buf_set_lines(new_buffer, 0, -1, false, { 'draft' })
assert(vim.json.decode(run('read_loaded_buffer', { buffer_id = new_buffer }, nil, context)).lines[1] == 'draft')
has(run('edit_loaded_buffer', { buffer_id = new_buffer, edits = { { old_text = 'draft', new_text = 'edited draft' } } }, nil, context), 'not saved')
assert(vim.fn.filereadable('new-unsaved.txt') == 0 and vim.bo[new_buffer].modified)
count = asked
assert(vim.json.decode(run('read_loaded_buffer', { buffer_id = outside }, inside)).lines[1] == 'external')
assert(asked == count + 1, 'external buffer reads must not inherit workspace trust')
has(run('read_file', { path = 'src/file.txt', buffer_id = inside }), 'unknown argument buffer_id')
has(run('read_loaded_buffer', { path = 'src/file.txt', buffer_id = inside }), 'unknown argument path')
has(run('read_source_buffer', { path = 'src/file.txt' }, unnamed), 'unknown argument path')
has(run('edit_file', { path = 'src/file.txt', buffer_id = inside, edits = { { old_text = 'saved', new_text = 'bad' } } }), 'unknown argument buffer_id')
has(run('edit_loaded_buffer', { buffer_id = inside, path = 'src/file.txt', edits = { { old_text = 'saved', new_text = 'bad' } } }), 'unknown argument path')
has(run('edit_source_buffer', { path = 'src/file.txt', edits = { { old_text = 'saved', new_text = 'bad' } } }, inside), 'unknown argument path')
has(run('edit_file', { edits = { { old_text = 'saved', new_text = 'bad' } } }, inside), 'missing argument path')
has(run('edit_loaded_buffer', { edits = { { old_text = 'saved', new_text = 'bad' } } }, inside), 'missing argument buffer_id')
has(run('edit_source_buffer', { edits = { { old_text = 'saved', new_text = 'bad' } } }), 'no source buffer')
has(run('edit_file', { path = 'src/file.txt', edits = { { old_text = 'saved', new_text = 'bad', start_line = 1 } } }), 'both start_line')
has(run('edit_file', { path = 'src/file.txt' }), 'missing argument edits')
has(run('edit_loaded_buffer', { buffer_id = inside }), 'missing argument edits')
has(run('edit_source_buffer', {}, inside), 'missing argument edits')
has(run('edit_file', { path = 'src/file.txt', old_text = 'saved', new_text = 'bad' }), 'missing argument edits')
has(run('edit_source_buffer', { edits = { { old_text = 'saved', new_text = 'bad' } }, old_text = 'saved' }, inside), 'unknown argument old_text')
has(run('edit_file', { path = 'src/file.txt', edits = { { old_text = 'saved', new_text = 'bad' } }, start_line = 1 }), 'unknown argument start_line')
has(run('read_loaded_buffer', { buffer_id = scratch }), 'ordinary file buffers')
has(run('read_file', {}), 'missing argument path')
has(run('read_loaded_buffer', {}), 'missing argument buffer_id')
has(run('read_source_buffer', {}), 'no source buffer')
has(run('read_loaded_buffer', { buffer_id = 0 }), 'Error:')
has(run('read_buffer', {}), 'unknown tool')
has(run('replace_buffer_lines', {}), 'unknown tool')

-- Large files remain editable by either target type, with no 200KB file limit.
local many = {}
for i = 1, 5000 do many[i] = string.rep('x', 90) end
many[4000] = 'unique target'
vim.fn.writefile(many, 'large.txt')
read = vim.json.decode(run('read_file', { path = 'large.txt', start_line = 4000, end_line = 4000 }, nil, context))
has(run('edit_file', { path = 'large.txt', edits = { { old_text = 'unique target', new_text = 'first change' } } }, nil, context), 'saved file')
has(run('edit_loaded_buffer', { buffer_id = read.buffer_id, edits = { { old_text = 'first change', new_text = 'second change' } } }, nil, context), 'saved file')
local disk = vim.fn.readfile('large.txt')
assert(#disk == 5000 and disk[3999] == many[3999] and disk[4000] == 'second change' and disk[4001] == many[4001])

-- Path deletion / buffer renaming while approval is open cannot bypass guards.
local pending, result
writes.show = function(_, _, cb) pending = cb end
tools.execute('edit_file', { path = 'src/file.txt', edits = { { old_text = 'saved', new_text = 'bad' } } }, nil,
  function(value) result = value end, function() return true end, context)
vim.fn.delete('src/file.txt')
pending('once')
has(result, 'changed while awaiting confirmation')
assert(vim.fn.filereadable('src/file.txt') == 0)
result = nil
tools.execute('edit_loaded_buffer', { buffer_id = unnamed, edits = { { old_text = 'first', new_text = 'bad' } } }, nil,
  function(value) result = value end, function() return true end, context)
vim.api.nvim_buf_set_name(unnamed, dir .. '/renamed.txt')
pending('once')
has(result, 'changed while awaiting confirmation')
assert(vim.fn.filereadable('renamed.txt') == 0)

-- Skill tools disappear when unavailable, disabled or untrusted (including globals).
local function names(specs)
  local result = {}
  for _, spec in ipairs(specs) do result[spec['function'].name] = true end
  return result
end
assert(not names(tools.request_specs(dir, nil)).load_skill)
assert(not names(tools.request_specs(dir, 'all')).read_buffer)
assert(not names(tools.request_specs(dir, 'all')).replace_buffer_lines)
vim.fn.mkdir(dir .. '/.agents/skills/example', 'p')
local skill_path = dir .. '/.agents/skills/example/SKILL.md'
vim.fn.writefile({ '---', 'description: Useful test skill', '---', 'instructions' }, skill_path)
assert(names(tools.request_specs(dir, 'all')).load_skill)
files.set_disabled(dir, { [skill_path] = true })
-- Also disable any global skills so this assertion is independent of user configuration.
local disabled = { [skill_path] = true }
for _, entry in ipairs(files.entries(dir, 'all')) do if entry.kind == 'skill' then disabled[entry.path] = true end end
files.set_disabled(dir, disabled)
assert(not names(tools.request_specs(dir, 'all')).load_skill)
count = asked
has(run('load_skill', { name = 'example' }), 'disabled')
assert(asked == count, 'unavailable skill calls should not prompt')
files.set_disabled(dir, {})
assert(names(tools.request_specs(dir, 'all')).load_skill)
-- No available skills means no tool, even when trust exists.
vim.fn.delete(skill_path)
local globals_disabled = {}
for _, entry in ipairs(files.entries(dir, 'all')) do
  if entry.kind == 'skill' then globals_disabled[entry.path] = true end
end
files.set_disabled(dir, globals_disabled)
assert(not names(tools.request_specs(dir, 'all')).load_skill)
vim.fn.writefile({ 'instructions' }, skill_path)
assert(names(tools.request_specs(dir, 'all')).load_skill)
approval.setup({})
has(run('load_skill', { name = 'example' }), 'not trusted')
vim.cmd.cd(root)
vim.fn.delete(dir, 'rf')
vim.fn.delete(other, 'rf')
print('codeit unified tool tests passed')
