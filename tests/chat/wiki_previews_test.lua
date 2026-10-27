vim.opt.runtimepath:prepend(vim.fn.getcwd())
local wiki = require('codeit.wiki')
local uv = vim.uv
local temp = vim.fn.tempname()
vim.fn.mkdir(temp, 'p')
local function page(path)
  return { path = path, content = '---\ntitle: Page\n---\n\nBody.\n', summary = 'Page summary.' }
end
local function snapshot(root)
  local store = assert(wiki.open(root))
  assert(wiki.catalog(store))
  return store
end

local root = temp .. '/wiki'
local store = snapshot(root)
assert(wiki.apply(store, { page('notes/page.md'), page('projects/page.md') }))
for _, category in ipairs({ 'notes', 'projects' }) do
  assert(vim.fn.filereadable(root .. '/.previews/' .. category .. '/page.md') == 1)
  assert(vim.fn.filereadable(root .. '/' .. category .. '/.page.md') == 0)
end
local catalog = assert(wiki.catalog(store))
assert(#catalog == 2, 'preview folders must not be cataloged as wiki pages')
for _, entry in ipairs(catalog) do assert(entry.preview == 'Page summary.') end

-- Old sidecars move unchanged; invalid summaries are then refreshed normally.
vim.fn.delete(root .. '/.previews/notes/page.md')
vim.fn.writefile({ 'Legacy summary without a fingerprint.' }, root .. '/notes/.page.md')
store = snapshot(root)
assert(vim.fn.filereadable(root .. '/notes/.page.md') == 0)
assert(vim.fn.readfile(root .. '/.previews/notes/page.md')[1] == 'Legacy summary without a fingerprint.')
local batch = wiki.summary_batch(store)
assert(#batch == 1 and batch[1].path == 'notes/page.md')
assert(wiki.apply_summaries(store, { { path = 'notes/page.md', summary = 'Refreshed summary.' } }, batch))
assert(vim.fn.filereadable(root .. '/.previews/notes/page.md') == 1)
assert(vim.fn.filereadable(root .. '/notes/.page.md') == 0)
assert(#wiki.summary_batch(snapshot(root)) == 0)

-- Reject unsafe preview parents before reading or writing through them.
local outside = temp .. '/outside'
vim.fn.mkdir(outside .. '/notes', 'p')
vim.fn.writefile({ 'Do not change.' }, outside .. '/notes/page.md')
for index, relative in ipairs({ '.previews', '.previews/notes' }) do
  local unsafe_root = temp .. '/unsafe-' .. index
  local unsafe_store = snapshot(unsafe_root)
  assert(wiki.apply(unsafe_store, { page('notes/page.md') }))
  vim.fn.delete(unsafe_root .. '/' .. relative, 'rf')
  local target = relative == '.previews' and outside or outside .. '/notes'
  if uv.fs_symlink(target, unsafe_root .. '/' .. relative) then
    assert(not wiki.catalog(unsafe_store), 'must not read through symlinked preview parents')
    assert(not wiki.apply(unsafe_store, { page('projects/new.md'), page('notes/new.md') }),
      'must validate every preview parent before writing')
    assert(vim.fn.filereadable(unsafe_root .. '/projects/new.md') == 0)
    assert(vim.fn.readfile(outside .. '/notes/page.md')[1] == 'Do not change.')
    uv.fs_unlink(unsafe_root .. '/' .. relative)
  end
end

local blocked_root = temp .. '/blocked'
local blocked_store = snapshot(blocked_root)
vim.fn.writefile({ 'Not a directory.' }, blocked_root .. '/.previews')
assert(not wiki.apply(blocked_store, { page('notes/page.md') }))
assert(vim.fn.filereadable(blocked_root .. '/notes/page.md') == 0)

vim.fn.delete(temp, 'rf')
print('personal wiki preview layout tests passed')
