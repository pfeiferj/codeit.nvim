vim.opt.runtimepath:prepend(vim.fn.getcwd())
local wiki = require('codeit.wiki')
local root = vim.fn.tempname()
local function page(path, content, previous_path)
  return { path = path, content = content or '---\ntitle: Page\n---\n\nBody.\n',
    summary = 'Page summary.', previous_path = previous_path }
end
local function snapshot()
  local store = assert(wiki.open(root))
  assert(wiki.catalog(store))
  return store
end
local function text(path)
  return table.concat(vim.fn.readfile(root .. '/' .. path, 'b'), '\n')
end
local function git(...)
  local result = vim.fn.system(vim.list_extend({ 'git', '-C', root }, { ... }))
  assert(vim.v.shell_error == 0, result)
  return vim.trim(result)
end
local old = 'notes/old.md'
local destination = 'projects/new.md'
local original = '---\ntitle: Old\ncustom: keep\n---\n\n[Peer](peer.md)\n[Self](old.md#section)\n'
local backlink = '---\ntitle: Index\nexample: "[[old]]"\n---\n\n[Old](old.md#section)\n[[old|Label]]\n'
  .. '[[notes/old.md#section]]\n[reference]: <old.md> "Title"\n[Web](https://example.com/old.md)\n'
  .. '```markdown\n[Example](old.md)\n```\n`[[old]]` and [Actual](old.md)\n    [[old]]\n'
  .. '[Titled](old.md "Keep title")\n[Angled](<old.md> "Keep title")\n'
local store = snapshot()
assert(wiki.apply(store, { page(old, original), page('notes/peer.md'), page('notes/index.md', backlink) }))
local rename = page(destination, original:gsub('title: Old', 'title: New\naliases: [Old]'), old)
store = snapshot()
assert(not wiki.apply(store, { rename }), 'rename must require selection of the source')
assert(wiki.select(store, { old }))
for _, target in ipairs({ '../escape.md', 'notes/peer.md', old }) do
  assert(not wiki.apply(store, { page(target, original, old) }), 'must reject unsafe or occupied destinations')
end
assert(not wiki.apply(store, { rename, page('notes/another.md', original, old) }), 'cannot rename a source twice')
assert(not wiki.apply(store, { rename, page(old) }), 'cannot recreate a rename source in the same batch')
assert(not wiki.apply(store, { page(destination, original, 'notes/missing.md') }))
assert(not wiki.apply(store, { { path = destination, previous_path = old } }), 'malformed content must not throw')

local function unsaved(path)
  local buffer = vim.fn.bufadd(root .. '/' .. path)
  vim.fn.bufload(buffer)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { '# Unsaved' })
  assert(not wiki.apply(store, { rename }), 'must preserve unsaved edits: ' .. path)
  assert(vim.fn.filereadable(root .. '/' .. destination) == 0, 'must validate before writing')
  vim.api.nvim_buf_delete(buffer, { force = true })
end
unsaved(old)
unsaved('.previews/notes/old.md')
unsaved(destination)
unsaved('notes/index.md')
unsaved('.previews/notes/index.md')
for _, path in ipairs({ old, '.previews/notes/old.md', 'notes/index.md', '.previews/notes/index.md' }) do
  local before = text(path)
  vim.fn.writefile({ '# Concurrent edit' }, root .. '/' .. path)
  assert(not wiki.apply(store, { rename }), 'must preserve concurrent edits: ' .. path)
  local fd = assert(vim.uv.fs_open(root .. '/' .. path, 'w', 384))
  assert(vim.uv.fs_write(fd, before, 0))
  vim.uv.fs_close(fd)
end
for _, path in ipairs({ old, '.previews/notes/old.md', 'notes/index.md', '.previews/notes/index.md' }) do
  local before = text(path)
  vim.fn.writefile({ '# Staged edit' }, root .. '/' .. path)
  git('add', '--', path)
  local fd = assert(vim.uv.fs_open(root .. '/' .. path, 'w', 384))
  assert(vim.uv.fs_write(fd, before, 0))
  vim.uv.fs_close(fd)
  assert(not wiki.apply(store, { rename }), 'must preserve staged edits: ' .. path)
  git('reset', '--quiet', '--', path)
end
vim.fn.writefile({ '# Occupied' }, root .. '/' .. destination:gsub('projects/', 'notes/'))
assert(not wiki.apply(store, { page('notes/new.md', original, old) }), 'must preserve newly created destinations')
vim.fn.delete(root .. '/notes/new.md')
vim.fn.writefile({ 'Occupied preview' }, root .. '/.previews/notes/new.md')
assert(not wiki.apply(store, { page('notes/new.md', original, old) }), 'must preserve orphan destination previews')
vim.fn.delete(root .. '/.previews/notes/new.md')

local before = tonumber(git('rev-list', '--count', 'HEAD'))
assert(wiki.apply(store, { rename }))
assert(vim.fn.filereadable(root .. '/' .. old) == 0)
assert(vim.fn.filereadable(root .. '/.previews/notes/old.md') == 0)
assert(vim.fn.filereadable(root .. '/.previews/' .. destination) == 1)
local renamed = text(destination)
assert(renamed:find('title: New', 1, true) and renamed:find('custom: keep', 1, true))
assert(renamed:find('[Peer](../notes/peer.md)', 1, true), 'outgoing links must be rebased')
assert(renamed:find('[Self](new.md#section)', 1, true), 'self links must follow the rename')
local index = text('notes/index.md')
assert(index:find('[Old](../projects/new.md#section)', 1, true))
assert(index:find('[[projects/new|Label]]', 1, true))
assert(index:find('[[projects/new.md#section]]', 1, true))
assert(index:find('[reference]: <../projects/new.md> "Title"', 1, true))
assert(index:find('[Web](https://example.com/old.md)', 1, true))
assert(index:find('example: "[[old]]"', 1, true), 'frontmatter must be preserved')
assert(index:find('```markdown\n[Example](old.md)\n```', 1, true), 'fenced code must be preserved')
assert(index:find('`[[old]]` and [Actual](../projects/new.md)', 1, true), 'inline code must be preserved')
assert(index:find('    [[old]]', 1, true), 'indented code must be preserved')
assert(index:find('[Titled](../projects/new.md "Keep title")', 1, true))
assert(index:find('[Angled](<../projects/new.md> "Keep title")', 1, true))
assert(store.pages[old] == nil and store.pages[destination] == renamed, 'cache must reflect the rename')
assert(tonumber(git('rev-list', '--count', 'HEAD')) == before + 1, 'rename must create one commit')
assert(git('status', '--porcelain') == '', 'all rename and backlink changes must be committed')
store = snapshot()
assert(#wiki.summary_batch(store) == 0, 'rename and backlink previews must have current fingerprints')
assert(wiki.select(store, { destination }))
assert(wiki.apply(store, { page(destination, (renamed:gsub('title: New', 'title: Better title'))) }))
assert(text(destination):find('title: Better title', 1, true), 'title-only renames must work')
assert(wiki.update_prompt:find('previous_path', 1, true))
assert(wiki.update_prompt:find('update its title and/or rename its file', 1, true))
-- Imported frontmatter pages may not yet be tracked, and may lack a preview.
vim.fn.writefile({ '---', 'title: Imported', '---', '', 'Imported body.' }, root .. '/notes/imported.md')
store = snapshot()
assert(wiki.select(store, { 'notes/imported.md' }))
assert(wiki.apply(store, { page('projects/imported.md', text('notes/imported.md'), 'notes/imported.md') }))
assert(vim.fn.filereadable(root .. '/notes/imported.md') == 0)
assert(text('projects/imported.md'):find('Imported body.', 1, true))
assert(git('status', '--porcelain') == '', 'untracked source must not cause a failed commit')
vim.fn.delete(root, 'rf')
print('personal wiki rename tests passed')
