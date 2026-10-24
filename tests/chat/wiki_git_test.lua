vim.opt.runtimepath:prepend(vim.fn.getcwd())
local wiki = require('codeit.wiki')
local temp = vim.fn.tempname()
vim.fn.mkdir(temp, 'p')
local function git(root, args)
  local argv = { 'git', '-c', 'core.fsmonitor=false', '-c', 'commit.gpgSign=false',
    '-c', 'user.name=Test', '-c', 'user.email=test@example.com', '-C', root }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait(10000)
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end
local function snapshot(root, paths)
  local store = assert(wiki.open(root))
  assert(wiki.catalog(store))
  assert(wiki.select(store, paths or {}))
  return store
end
local function page(path, content, summary)
  return {
    path = path,
    content = content or '# Page\n\nDurable knowledge.\n',
    summary = summary or 'Durable knowledge about this page.',
  }
end

-- A wiki nested in an existing repository must have its own history.
git(temp, { 'init', '--', temp })
local root = temp .. '/wiki'
local store = snapshot(root)
assert(git(root, { 'rev-parse', '--show-toplevel' }) == root)
local branch = git(root, { 'symbolic-ref', 'HEAD' })
assert(wiki.apply(store, { page('notes/first.md'), page('notes/second.md') }))
assert(git(root, { 'rev-list', '--count', 'HEAD' }) == '1')
assert(git(root, { 'show', 'HEAD:notes/first.md' }):find('Durable knowledge.', 1, true))
assert(git(root, { 'show', 'HEAD:notes/.first.md' }):find('Durable knowledge about this page.', 1, true))
assert(git(root, { 'status', '--porcelain' }) == '')
assert(git(root, { 'symbolic-ref', 'HEAD' }) == branch)
assert(git(root, { 'log', '-1', '--format=%an <%ae>' }) == 'Codeit <codeit@localhost>')

local imported = temp .. '/imported'
vim.fn.mkdir(imported .. '/notes', 'p')
vim.fn.writefile({ '# Original', '', 'Before automatic updates.' }, imported .. '/notes/existing.md')
vim.fn.writefile({ 'not a wiki page' }, imported .. '/other.txt')
assert(wiki.apply(snapshot(imported, { 'notes/existing.md' }), { page('notes/existing.md', '# Updated\n') }))
assert(git(imported, { 'rev-list', '--count', 'HEAD' }) == '2')
assert(git(imported, { 'show', 'HEAD~:notes/existing.md' }):find('Before automatic updates.', 1, true))
assert(git(imported, { 'ls-tree', '-r', '--name-only', 'HEAD~' }) == 'notes/existing.md')

local head = git(root, { 'rev-parse', 'HEAD' })
assert(wiki.apply(snapshot(root, { 'notes/first.md' }), { page('notes/first.md') }))
assert(wiki.apply(snapshot(root), {}))
assert(git(root, { 'rev-parse', 'HEAD' }) == head, 'no-op updates must not create commits')

-- Keep the current branch and preserve unrelated staged and unstaged edits.
git(root, { 'checkout', '-b', 'wiki-notes' })
vim.fn.writefile({ 'staged content' }, root .. '/unrelated.txt')
git(root, { 'add', '--', 'unrelated.txt' })
vim.fn.writefile({ 'unstaged content' }, root .. '/unrelated.txt')
vim.fn.writefile({ '# Manual', '', 'Uncommitted user edit.' }, root .. '/notes/second.md')
git(root, { 'config', 'remote.origin.url', 'https://example.invalid/wiki.git' })
-- Automated commits must not run arbitrary repository hooks (which could push).
vim.fn.mkdir(root .. '/hooks', 'p')
vim.fn.writefile({ '#!/bin/sh', 'exit 1' }, root .. '/hooks/pre-commit')
assert(vim.uv.fs_chmod(root .. '/hooks/pre-commit', 448))
git(root, { 'config', 'core.hooksPath', root .. '/hooks' })
assert(wiki.apply(snapshot(root, { 'notes/first.md' }), { page('notes/first.md', '# First\n\nUpdated fact.\n') }))
assert(git(root, { 'branch', '--show-current' }) == 'wiki-notes')
assert(git(root, { 'diff-tree', '--no-commit-id', '--name-only', '-r', 'HEAD' }) == 'notes/.first.md\nnotes/first.md')
assert(git(root, { 'diff', '--cached', '--name-only' }) == 'unrelated.txt')
assert(git(root, { 'show', ':unrelated.txt' }) == 'staged content')
assert(table.concat(vim.fn.readfile(root .. '/unrelated.txt'), '\n') == 'unstaged content')
assert(git(root, { 'show', 'HEAD:notes/second.md' }):find('Durable knowledge.', 1, true))
assert(git(root, { 'show', 'HEAD:notes/.second.md' }):find('Durable knowledge about this page.', 1, true))
assert(git(root, { 'config', 'remote.origin.url' }) == 'https://example.invalid/wiki.git')
assert(git(root, { 'config', 'core.hooksPath' }) == root .. '/hooks', 'do not change repository configuration')
local unchanged_head = git(root, { 'rev-parse', 'HEAD' })
assert(wiki.apply(snapshot(root, { 'notes/first.md' }), { page('notes/first.md', '# First\n\nUpdated fact.\n') }))
assert(git(root, { 'rev-parse', 'HEAD' }) == unchanged_head)
assert(git(root, { 'diff', '--cached', '--name-only' }) == 'unrelated.txt')

-- A staged edit to a target page must not be silently consumed by automation.
git(root, { 'add', '--', 'notes/second.md' })
local staged_head = git(root, { 'rev-parse', 'HEAD' })
local ok, err = wiki.apply(snapshot(root, { 'notes/second.md' }), { page('notes/second.md', '# Replacement\n') })
assert(not ok and err:find('staged', 1, true))
assert(git(root, { 'rev-parse', 'HEAD' }) == staged_head)
assert(table.concat(vim.fn.readfile(root .. '/notes/second.md'), '\n'):find('Uncommitted user edit.', 1, true))

-- Staged and unsaved summary edits must also be preserved.
local summary_store = snapshot(root, { 'notes/first.md' })
vim.fn.writefile({ 'externally edited summary' }, root .. '/notes/.first.md')
ok, err = wiki.apply(summary_store, { page('notes/first.md', '# First\n\nUpdated again.\n', 'Updated summary.') })
assert(not ok and err:find('summary changed', 1, true))
vim.fn.writefile({ '<!-- codeit-source-sha256: ' .. vim.fn.sha256('# First\n\nUpdated again.\n') .. ' -->', 'Updated summary.' }, root .. '/notes/.first.md')
git(root, { 'add', '--', 'notes/.first.md' })
ok, err = wiki.apply(snapshot(root, { 'notes/first.md' }), { page('notes/first.md', '# First\n\nUpdated again.\n', 'Another summary.') })
assert(not ok and err:find('staged', 1, true))
git(root, { 'reset', '--', 'notes/.first.md' })
local summary_buffer = vim.fn.bufadd(root .. '/notes/.first.md')
vim.fn.bufload(summary_buffer)
vim.api.nvim_buf_set_lines(summary_buffer, 0, -1, false, { 'unsaved summary edit' })
ok, err = wiki.apply(snapshot(root, { 'notes/first.md' }), { page('notes/first.md', '# First\n\nUpdated again.\n', 'Another summary.') })
assert(not ok and err:find('unsaved', 1, true))
vim.api.nvim_buf_delete(summary_buffer, { force = true })

local detached = temp .. '/detached'
assert(wiki.apply(snapshot(detached), { page('notes/page.md') }))
git(detached, { 'checkout', '--detach', 'HEAD' })
ok, err = wiki.apply(snapshot(detached, { 'notes/page.md' }), { page('notes/page.md', '# Changed\n') })
assert(not ok and err:find('checked-out branch', 1, true))
assert(git(detached, { 'show', 'HEAD:notes/page.md' }):find('Durable knowledge.', 1, true))

-- Report Git failures rather than claiming that an uncommitted update succeeded.
local system = vim.system
vim.system = function(argv, options)
  if vim.tbl_contains(argv, 'commit') then
    return { wait = function() return { code = 1, stderr = 'simulated commit failure' } end }
  end
  return system(argv, options)
end
ok, err = wiki.apply(snapshot(root), { page('notes/new.md') })
vim.system = system
assert(not ok and err:find('simulated commit failure', 1, true))
assert(vim.fn.filereadable(root .. '/notes/new.md') == 1)
assert(git(root, { 'rev-parse', 'HEAD' }) == staged_head)
assert(git(root, { 'diff', '--cached', '--name-only' }) == 'notes/second.md\nunrelated.txt')
assert(wiki.apply(snapshot(root, { 'notes/new.md' }), { page('notes/new.md') }))
assert(git(root, { 'show', 'HEAD:notes/new.md' }):find('Durable knowledge.', 1, true))
assert(git(root, { 'show', 'HEAD:notes/.new.md' }):find('Durable knowledge about this page.', 1, true))
assert(git(root, { 'diff', '--cached', '--name-only' }) == 'notes/second.md\nunrelated.txt')

local unborn = temp .. '/unborn'
local unborn_store = snapshot(unborn)
vim.system = function(argv, options)
  if vim.tbl_contains(argv, 'commit') then
    return { wait = function() return { code = 1, stderr = 'simulated first commit failure' } end }
  end
  return system(argv, options)
end
ok, err = wiki.apply(unborn_store, { page('notes/page.md') })
vim.system = system
assert(not ok and err:find('simulated first commit failure', 1, true))
assert(git(unborn, { 'diff', '--cached', '--name-only' }) == '')
assert(wiki.apply(snapshot(unborn, { 'notes/page.md' }), { page('notes/page.md') }))

vim.system = function() error('git unavailable') end
ok, err = wiki.open(temp .. '/missing-git')
vim.system = system
assert(not ok and err:find('git unavailable', 1, true))
vim.fn.delete(temp, 'rf')
print('personal wiki Git tests passed')
