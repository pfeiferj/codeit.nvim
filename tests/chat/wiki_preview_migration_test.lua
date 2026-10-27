vim.opt.runtimepath:prepend(vim.fn.getcwd())
local wiki = require('codeit.wiki')
local uv = vim.uv
local temp = vim.fn.tempname()
vim.fn.mkdir(temp, 'p')
local content = '---\ntitle: Page\n---\n\nBody.\n'
local summary = '<!-- codeit-source-sha256: ' .. vim.fn.sha256(content) .. ' -->\nPage summary.'
local function write(path, text)
  local fd = assert(uv.fs_open(path, 'w', 384))
  assert(uv.fs_write(fd, text, 0))
  uv.fs_close(fd)
end
local function text(path)
  return table.concat(vim.fn.readfile(path, 'b'), '\n')
end
local function git(root, ...)
  local argv = { 'git', '-c', 'core.fsmonitor=false', '-c', 'core.hooksPath=/dev/null',
    '-c', 'commit.gpgSign=false', '-c', 'user.name=Test', '-c', 'user.email=test@localhost', '-C', root }
  vim.list_extend(argv, { ... })
  local result = vim.system(argv, { text = true }):wait(10000)
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end
local function legacy(name, tracked)
  local root = temp .. '/' .. name
  local store = assert(wiki.open(root))
  vim.fn.mkdir(root .. '/notes', 'p')
  write(root .. '/notes/page.md', content)
  write(root .. '/notes/.page.md', summary)
  if tracked then
    git(root, 'add', '--', 'notes/page.md', 'notes/.page.md')
    git(root, 'commit', '-m', 'Original wiki')
    store = assert(wiki.open(root))
  end
  return root, store
end

local root, store = legacy('tracked', true)
-- Unrelated index entries and manual main-page edits must remain untouched.
write(root .. '/unrelated.txt', 'Staged content.')
git(root, 'add', '--', 'unrelated.txt')
write(root .. '/notes/page.md', content .. 'Manual addition.\n')
local catalog = assert(wiki.catalog(store))
assert(#catalog == 1 and catalog[1].preview == nil, 'stale fingerprints remain stale')
assert(text(root .. '/.previews/notes/page.md') == summary, 'migration must preserve exact bytes')
assert(vim.fn.filereadable(root .. '/notes/.page.md') == 0)
assert(git(root, 'show', 'HEAD:notes/page.md') == vim.trim(content), 'main-page edits must not be committed')
assert(text(root .. '/notes/page.md') == content .. 'Manual addition.\n')
assert(git(root, 'diff', '--cached', '--name-only') == 'unrelated.txt')
assert(git(root, 'diff-tree', '--no-commit-id', '--name-only', '--no-renames', '-r', 'HEAD')
  == '.previews/notes/page.md\nnotes/.page.md')
local head = git(root, 'rev-parse', 'HEAD')
assert(wiki.catalog(store))
assert(git(root, 'rev-parse', 'HEAD') == head, 'migration must be idempotent')

root, store = legacy('untracked', false)
catalog = assert(wiki.catalog(store))
assert(catalog[1].preview == 'Page summary.')
assert(#wiki.summary_batch(store) == 0, 'current migrated previews require no regeneration')
assert(text(root .. '/.previews/notes/page.md') == summary)
assert(git(root, 'status', '--porcelain') == '')

-- When both exist, leave the old file untouched and prefer the destination.
write(root .. '/notes/.page.md', 'Old duplicate.')
assert(wiki.catalog(store)[1].preview == 'Page summary.')
assert(text(root .. '/notes/.page.md') == 'Old duplicate.')

for _, location in ipairs({ 'notes/.page.md', '.previews/notes/page.md' }) do
  root, store = legacy('unsaved-' .. location:gsub('/', '-'), true)
  local buffer = vim.fn.bufadd(root .. '/' .. location)
  vim.fn.bufload(buffer)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { 'Unsaved preview.' })
  local ok, err = wiki.catalog(store)
  assert(not ok and err:find('unsaved', 1, true))
  assert(text(root .. '/notes/.page.md') == summary)
  assert(vim.fn.filereadable(root .. '/.previews/notes/page.md') == 0)
  vim.api.nvim_buf_delete(buffer, { force = true })
  assert(wiki.catalog(store))
end

root, store = legacy('staged', true)
write(root .. '/notes/.page.md', 'Staged preview edit.')
git(root, 'add', '--', 'notes/.page.md')
local ok, err = wiki.catalog(store)
assert(not ok and err:find('staged', 1, true))
assert(text(root .. '/notes/.page.md') == 'Staged preview edit.')
assert(vim.fn.filereadable(root .. '/.previews/notes/page.md') == 0)

root, store = legacy('symlink', true)
vim.fn.delete(root .. '/notes/.page.md')
if uv.fs_symlink(root .. '/notes/page.md', root .. '/notes/.page.md') then
  assert(not wiki.catalog(store), 'legacy preview symlinks must not be followed')
  assert(vim.fn.filereadable(root .. '/.previews/notes/page.md') == 0)
end

vim.fn.delete(temp, 'rf')
print('personal wiki preview migration tests passed')
