vim.opt.runtimepath:prepend(vim.fn.getcwd())
local temp = vim.fn.tempname()
vim.fn.mkdir(temp, 'p')
vim.fn.chdir(temp)
local wiki = require('codeit.wiki')
assert(wiki.plan_prompt:find('split large topics', 1, true), 'planning must account for page splitting')
assert(wiki.update_prompt:find('when splitting a large page', 1, true), 'new pages must be allowed for splits')
assert(wiki.update_prompt:find('one canonical page', 1, true), 'shared information must use canonical references')
assert(wiki.update_prompt:find('keep links valid when splitting', 1, true), 'splits must preserve navigation')
local root = temp .. '/wiki'
local function page(path, content)
  return { path = path, content = content or '# Editor\n\nUses Neovim.\n', summary = 'Summary of ' .. path }
end
local function snapshot()
  local store = assert(wiki.open(root))
  assert(wiki.catalog(store))
  return store
end
assert(not wiki.valid_path('../outside.md'))
assert(not wiki.valid_path('category/../../outside.md'))
assert(not wiki.valid_path('/tmp/outside.md'))
assert(not wiki.valid_path('a/b/c.md'))
assert(wiki.valid_path('preferences/editor.md'))
assert(wiki.valid_path(string.rep('a', 200) .. '/' .. string.rep('b', 200) .. '.md'))
assert(not wiki.valid_path(string.rep('a', 201) .. '/page.md'))
assert(not wiki.valid_path('category/' .. string.rep('b', 201) .. '.md'))
local store = snapshot()
assert(wiki.apply(store, { page('preferences/editor.md') }))
store = snapshot()
assert(not wiki.apply(store, { page('preferences/editor.md', '# Changed\n') }), 'must read a page before replacing it')
assert(wiki.select(store, { 'preferences/editor.md' }))
assert(not wiki.select(store, { 'missing/page.md' }))
assert(not wiki.select(store, { 'preferences/editor.md', 'preferences/editor.md' }))
assert(not wiki.apply(store, { page('preferences/editor.md'), page('../escape.md') }))
assert(not wiki.apply(store, { page('notes/bad.md', 'not Markdown') }))
assert(not wiki.apply(store, { page('notes/big.md', '# Big\n' .. string.rep('x', 327680)) }))
local filename = root .. '/preferences/editor.md'
vim.fn.writefile({ '# Manual', '', 'User edit.' }, filename)
assert(not wiki.apply(store, { page('preferences/editor.md') }), 'must preserve concurrent disk edits')
store = snapshot()
assert(wiki.select(store, { 'preferences/editor.md' }))
local buffer = vim.fn.bufadd(filename)
vim.fn.bufload(buffer)
vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { '# Unsaved' })
assert(not wiki.apply(store, { page('preferences/editor.md') }), 'must preserve unsaved edits')
vim.api.nvim_buf_delete(buffer, { force = true })
local outside = temp .. '/outside'
vim.fn.mkdir(outside, 'p')
if vim.uv.fs_symlink(outside, root .. '/linked', { dir = true }) then
  assert(not wiki.apply(snapshot(), { page('linked/escape.md') }))
end
vim.fn.writefile({ '# Outside' }, outside .. '/page.md')
if vim.uv.fs_symlink(outside .. '/page.md', root .. '/preferences/linked.md') then
  assert(not wiki.apply(snapshot(), { page('preferences/linked.md') }))
end
assert(not wiki.decode({ content = 'invalid' }))
assert(wiki.decode({ content = '```json\n{"pages":[]}\n```' }))

local metadata_root = temp .. '/metadata-wiki'
local metadata = assert(wiki.open(metadata_root))
local content = '---\ntitle: Editor preferences\ntags:\n  - tools/editor\naliases: [Editing setup]\ncustom: keep-me\n---\n\nUses Neovim.\n'
assert(wiki.apply(metadata, { page('preferences/editor.md', content) }))
assert(not wiki.apply(metadata, { page('notes/bad.md', '---\ntitle: Editor\nBody without closing delimiter\n') }))
assert(not wiki.apply(metadata, { page('notes/bad.md', '---\ntags: []\n---\n\nNo title.\n') }))
assert(not wiki.apply(metadata, { page('notes/bad.md', '---\ntitle: ""\n---\n\nEmpty title.\n') }))
for _, title in ipairs({ '# comment', 'null', 'true', '42', 'a: b', "''", 'First\ntitle: Second' }) do
  assert(not wiki.apply(metadata, { page('notes/bad.md', '---\ntitle: ' .. title .. '\n---\nBody.\n') }), title)
end
assert(wiki.apply(metadata, { page('notes/crlf.md', '---\r\ntitle: CRLF\r\n---\r\n\r\nBody.\r\n') }))
metadata = assert(wiki.open(metadata_root))
assert(wiki.catalog(metadata))
for _, query in ipairs({ 'TOOLS/EDITOR', 'Editing setup', 'Editor preferences' }) do
  local found = assert(wiki.search(metadata, { query }))
  assert(#found == 1 and found[1].path == 'preferences/editor.md', 'frontmatter must be searchable')
end
local legacy = '# A "quoted": title\r\n\r\nKeep this body.\r\n## Section\r\n[[Other note]]\r\n'
assert(wiki.apply(metadata, { page('notes/legacy.md', legacy) }))
metadata = assert(wiki.open(metadata_root))
assert(wiki.catalog(metadata))
local legacy_file = metadata_root .. '/notes/legacy.md'
local legacy_buffer = vim.fn.bufadd(legacy_file)
vim.fn.bufload(legacy_buffer)
vim.api.nvim_buf_set_lines(legacy_buffer, 0, -1, false, { '# Unsaved' })
assert(not wiki.migrate(metadata), 'migration must preserve unsaved edits')
vim.api.nvim_buf_delete(legacy_buffer, { force = true })
-- Stage different bytes without changing the cataloged working tree.
vim.fn.writefile({ '# Staged version' }, legacy_file)
vim.fn.system({ 'git', '-C', metadata_root, 'add', '--', 'notes/legacy.md' })
local legacy_fd = assert(vim.uv.fs_open(legacy_file, 'w', 384))
assert(vim.uv.fs_write(legacy_fd, legacy, 0))
vim.uv.fs_close(legacy_fd)
assert(not wiki.migrate(metadata), 'migration must preserve staged page edits')
vim.fn.system({ 'git', '-C', metadata_root, 'reset', '--quiet', '--', 'notes/legacy.md' })
assert(wiki.migrate(metadata))
local migrated = metadata.pages['notes/legacy.md']
assert(migrated == '---\ntitle: "A \\"quoted\\": title"\ntags: []\naliases: []\n---\n\r\nKeep this body.\r\n## Section\r\n[[Other note]]\r\n')
assert(metadata.pages['preferences/editor.md'] == content, 'migration must preserve existing properties')
local migrated_catalog = assert(wiki.catalog(metadata))
assert(#wiki.summary_batch(metadata) == 0, 'migration must refresh summary fingerprints')
local head = vim.fn.system({ 'git', '-C', metadata_root, 'rev-parse', 'HEAD' })
assert(wiki.migrate(metadata))
assert(vim.fn.system({ 'git', '-C', metadata_root, 'rev-parse', 'HEAD' }) == head, 'migration must be idempotent')
assert(#migrated_catalog == 3)
vim.fn.writefile({ '# Title only' }, metadata_root .. '/notes/title-only.md', 'b')
assert(wiki.catalog(metadata))
local title_batch = wiki.summary_batch(metadata)
assert(wiki.apply_summaries(metadata, { { path = 'notes/title-only.md', summary = 'Title only.' } }, title_batch))
assert(wiki.migrate(metadata))
assert(metadata.pages['notes/title-only.md']:find('title: "Title only"', 1, true))

local migration_root = temp .. '/migration-batches'
local migration_store = assert(wiki.open(migration_root))
local migration_pages = {}
for i = 1, 80 do migration_pages[i] = page('notes/page-' .. i .. '.md') end
assert(wiki.apply(migration_store, migration_pages))
assert(wiki.apply(migration_store, { page('notes/page-81.md') }))
migration_store = assert(wiki.open(migration_root))
assert(wiki.catalog(migration_store))
assert(wiki.migrate(migration_store))
for _, text in pairs(migration_store.pages) do assert(text:match('^%-%-%-\ntitle:')) end
assert(#wiki.summary_batch(migration_store) == 0)
assert(vim.trim(vim.fn.system({ 'git', '-C', migration_root, 'rev-list', '--count', 'HEAD' })) == '4',
  '81 legacy pages must migrate in two safe batches')

local limits_root = temp .. '/limits-wiki'
local limits_store = assert(wiki.open(limits_root))
local updates, paths = {}, {}
for i = 1, 80 do
  paths[i] = 'notes/page-' .. i .. '.md'
  updates[i] = page(paths[i], '# Page\n' .. string.rep('x', 327680 - 7))
end
assert(wiki.apply(limits_store, updates), 'must accept 80 pages at the new size limit')
limits_store = assert(wiki.open(limits_root))
local catalog = assert(wiki.catalog(limits_store))
assert(#catalog == 80 and catalog[1].preview == 'Summary of ' .. catalog[1].path, 'previews must use sidecar summaries')
assert(#assert(wiki.select(limits_store, paths)) == 80)
paths[81] = 'notes/page-81.md'
updates[81] = page(paths[81])
assert(not wiki.select(limits_store, paths), 'must reject selections over 80 pages')
assert(not wiki.apply(limits_store, updates), 'must reject updates over 80 pages')
vim.fn.writefile({ '# Big', string.rep('x', 327680) }, limits_root .. '/notes/oversized.md')
assert(not wiki.catalog(assert(wiki.open(limits_root))), 'must reject oversized pages on read')

local summary_root = temp .. '/summary-wiki'
local summary_store = assert(wiki.open(summary_root))
local without_summary = page('notes/page.md')
without_summary.summary = nil
assert(not wiki.apply(summary_store, { without_summary }), 'page writes must require summaries')
without_summary.summary = string.rep('x', 5001)
assert(not wiki.apply(summary_store, { without_summary }), 'summaries must be bounded')
without_summary.summary = ' \n'
assert(not wiki.apply(summary_store, { without_summary }), 'summaries must not be blank')
assert(wiki.apply(summary_store, { page('notes/page.md') }))
assert(vim.fn.filereadable(summary_root .. '/notes/.page.md') == 1)
summary_store = assert(wiki.open(summary_root))
assert(wiki.catalog(summary_store))
assert(#wiki.summary_batch(summary_store) == 0)
vim.fn.delete(summary_root .. '/notes/.page.md')
assert(wiki.catalog(summary_store))
local summary_batch = wiki.summary_batch(summary_store)
assert(#summary_batch == 1, 'recataloging must discard cached previews')
vim.fn.writefile({ '# Changed while summarizing' }, summary_root .. '/notes/page.md')
assert(not wiki.apply_summaries(summary_store, { { path = 'notes/page.md', summary = 'Old summary.' } }, summary_batch),
  'summary refresh must preserve concurrent source edits')
assert(vim.fn.filereadable(summary_root .. '/notes/.page.md') == 0)
assert(wiki.catalog(summary_store))
summary_batch = wiki.summary_batch(summary_store)
assert(wiki.apply_summaries(summary_store, { { path = 'notes/page.md', summary = string.rep('s', 5000) } }, summary_batch))
assert(assert(wiki.search(summary_store, { 'notes' }))[1].preview == string.rep('s', 5000))
vim.fn.writefile({ 'Imported text without a Markdown heading.' }, summary_root .. '/notes/plain.md')
assert(wiki.catalog(summary_store))
summary_batch = wiki.summary_batch(summary_store)
assert(wiki.apply_summaries(summary_store, { { path = 'notes/plain.md', summary = 'Imported plain text.' } }, summary_batch))
local fake_store = { pages = {}, previews = {} }
for i = 1, 6 do fake_store.pages['notes/page-' .. i .. '.md'] = '# Big\n' .. string.rep('x', 327000) end
summary_batch = wiki.summary_batch(fake_store)
assert(#summary_batch == 4, 'summary requests must be bounded by encoded page data')
vim.fn.delete(summary_root .. '/notes/.plain.md')
if vim.uv.fs_symlink(summary_root .. '/notes/page.md', summary_root .. '/notes/.plain.md') then
  assert(not wiki.catalog(summary_store), 'symlink preview files must not be followed')
end

local searchable = { pages = {
  ['preferences/editor.md'] = '# Editor\nUses Neovim.',
  ['notes/other.md'] = '# Other\nUnrelated information.',
  ['notes/long.md'] = '# Long\n' .. string.rep('x', 6000) .. 'needle.literal' .. string.rep('x', 6000),
} }
searchable.previews = {
  ['preferences/editor.md'] = 'Editor preference summary.',
  ['notes/other.md'] = 'Unrelated summary.',
  ['notes/long.md'] = 'Summary of a long page.',
}
local matches = assert(wiki.search(searchable, { 'NEOVIM', 'editor' }))
assert(#matches == 1 and matches[1].path == 'preferences/editor.md', 'search must match content and paths without duplicates')
matches = assert(wiki.search(searchable, { 'needle.literal' }))
assert(#matches == 1 and matches[1].preview == 'Summary of a long page.', 'previews must not be content excerpts')
assert(#assert(wiki.search(searchable, { 'needle.*' })) == 0, 'queries must be literal')
assert(#assert(wiki.search(searchable, {})) == 0)
assert(not wiki.search(searchable, { '' }))
assert(not wiki.search(searchable, { string.rep('x', 201) }))
assert(not wiki.search(searchable, 'Neovim'))
local too_many = {}
for i = 1, 21 do too_many[i] = 'term' end
assert(not wiki.search(searchable, too_many))
local many = { pages = {}, previews = {} }
for i = 1, 100 do
  local path = 'notes/page-' .. i .. '.md'
  many.pages[path], many.previews[path] = '# Match\n', 'Match summary.'
end
assert(#assert(wiki.search(many, { 'match' })) == 80, 'search results must be bounded')
assert(wiki.apply(snapshot(), { page('notes/unrelated.md', '# Unrelated\nNot for this review.\n') }))
local stale = snapshot()
local batch = wiki.summary_batch(stale)
assert(#batch == 1 and batch[1].path == 'preferences/editor.md', 'manual edits must invalidate the summary')
assert(not wiki.search(stale, { 'editor' }), 'stale summaries must never be returned')
assert(not wiki.apply_summaries(stale, {}, batch), 'every requested summary is required')
assert(not wiki.apply_summaries(stale, { { path = 'notes/unrelated.md', summary = 'Wrong page.' } }, batch))
assert(wiki.apply_summaries(stale, { { path = 'preferences/editor.md', summary = 'Manual editor preference.' } }, batch))
assert(#wiki.summary_batch(snapshot()) == 0)
assert(assert(wiki.search(snapshot(), { 'editor' }))[1].preview == 'Manual editor preference.')

local requests, callbacks = {}, {}
package.loaded['codeit.providers'] = {
  chat = function(config, messages, specs, callback)
    requests[#requests + 1] = { config = config, messages = messages, specs = specs }
    callbacks[#callbacks + 1] = callback
  end,
}
local plugin = require('codeit')
local history = require('codeit.chat.storage')
vim.fn.delete(vim.fn.stdpath('data') .. '/codeit/settings.json')
plugin.setup({ context_review = false, max_context_tokens = false, personal_wiki = { root = root },
  feature_settings = { personal_wiki = { model = 'wiki-model' } } })
local function response(index, value)
  callbacks[index]({ role = 'assistant', content = type(value) == 'string' and value or vim.json.encode(value) }, nil,
    { cost = 0.1, prompt_tokens = 20, completion_tokens = 10 })
end
local function wait_for(count)
  assert(vim.wait(1000, function() return #requests >= count end, 5), 'missing background wiki request')
  assert(#requests == count, 'unexpected request count: ' .. #requests)
end
plugin.send('I use Neovim.')
response(1, 'Understood.')
vim.wait(30, function() return false end, 5)
assert(#requests == 1, 'wiki must be disabled by default')
local values = plugin.get_settings()
assert(values.personal_wiki.enabled == false and values.personal_wiki.root == root)
values.personal_wiki.enabled = true
assert(plugin.configure(values, 'global'))
local settings = require('codeit.settings')
assert(settings.resolve(values, history.workspace()).personal_wiki.enabled)
for _, invalid in ipairs({ false, { enabled = 'yes', root = root }, { enabled = true, root = '../relative' },
  { enabled = true, root = root, unexpected = true } }) do
  local bad = vim.deepcopy(values)
  bad.personal_wiki = invalid
  assert(not plugin.configure(bad))
end
assert(not pcall(plugin.setup, { personal_wiki = { root = 'relative' } }))
plugin.setup({ context_review = false, max_context_tokens = false,
  personal_wiki = { enabled = true, root = root }, feature_settings = { personal_wiki = { model = 'wiki-model' } } })
plugin.send('I use Neovim for editing.')
response(2, 'Noted.')
wait_for(3)
assert(requests[3].config.model == 'wiki-model' and #requests[3].specs == 0)
local input = vim.json.decode(requests[3].messages[2].content)
assert(input.turn[1].content == 'I use Neovim for editing.' and input.catalog == nil and input.matches == nil)
plugin.send('My second turn while the review runs.')
assert(#requests == 4, 'wiki must not block the main agent')
response(3, { notes = 'User uses Neovim for editing.', queries = { 'editor', 'Neovim' } })
wait_for(5)
input = vim.json.decode(requests[5].messages[2].content)
assert(input.catalog == nil and input.turn == nil and #input.matches == 1)
assert(input.matches[1].path == 'preferences/editor.md' and input.matches[1].preview == 'Manual editor preference.')
response(5, { notes = 'User uses Neovim for editing.', paths = { 'preferences/editor.md' } })
wait_for(6)
input = vim.json.decode(requests[6].messages[2].content)
assert(input.catalog == nil and #input.matches == 1)
assert(input.pages[1].content:find('User edit.', 1, true), 'selected page contents must be read')
response(4, 'Second turn completed.')
assert(#requests == 6, 'reviews must serialize')
response(6, { pages = { page('preferences/editor.md', '# Editor\n\nUser edit.\n\nUses Neovim.\n') } })
wait_for(7)
assert(table.concat(vim.fn.readfile(filename), '\n'):find('Uses Neovim.', 1, true))
local saved = history.load(history.workspace(), history.list(history.workspace())[1].id)
assert(saved.cost_by_function.personal_wiki.requests == 3)
assert(saved.turn_costs[1].cost_by_function.personal_wiki.requests == 3)
assert(not saved.turn_costs[2].cost_by_function.personal_wiki)
local review = saved.turn_costs[1].wiki_review
assert(review.status == 'updated' and review.notes == 'User uses Neovim for editing.')
assert(vim.deep_equal(review.selected, { 'preferences/editor.md' }))
assert(vim.deep_equal(review.updated, { 'preferences/editor.md' }))
local transcript = table.concat(require('codeit.ui').chat_lines(), '\n')
assert(transcript:find('**Wiki review · updated**', 1, true))
assert(transcript:find('Updated pages: preferences/editor.md', 1, true))
assert(transcript:find('**Wiki review · updated**', 1, true)
  < transcript:find('My second turn while the review runs.', 1, true), 'summary must stay with its originating turn')
assert(saved.turn_costs[2].wiki_review.status == 'cancelled', 'unfinished saved reviews must not appear live after reload')
response(7, { notes = '', queries = {} })
vim.wait(30, function() return false end, 5)
assert(#requests == 7, 'nothing worth retaining needs no search results or update request')
saved = history.load(history.workspace(), history.list(history.workspace())[1].id)
assert(saved.turn_costs[2].wiki_review.status == 'skipped')
assert(saved.turn_costs[2].wiki_review.reason == 'Nothing worth retaining.')
plugin.send('Do not persist after I disable this feature.')
response(8, 'Done.')
wait_for(9)
values = plugin.get_settings()
values.personal_wiki.enabled = false
assert(plugin.configure(values))
response(9, { notes = 'A stale note.', queries = {} })
saved = history.load(history.workspace(), history.list(history.workspace())[1].id)
assert(saved.turn_costs[3].wiki_review.status == 'cancelled')
vim.wait(30, function() return false end, 5)
assert(#requests == 9, 'disabling must stop in-flight updates')
values.personal_wiki.enabled = true
assert(plugin.configure(values))
plugin.send('An invalid response should not wedge the queue.')
response(10, 'Done.')
wait_for(11)
response(11, 'not JSON')
saved = history.load(history.workspace(), history.list(history.workspace())[1].id)
assert(saved.turn_costs[4].wiki_review.status == 'failed')
assert(saved.turn_costs[4].wiki_review.reason == 'invalid wiki JSON response')
plugin.send('Try another review.')
response(12, 'Done.')
wait_for(13)
response(13, { notes = 'Durable note.', queries = { 'no matching topic' } })
wait_for(14)
input = vim.json.decode(requests[14].messages[2].content)
assert(input.catalog == nil and #input.matches == 0, 'no matches must not expose unrelated pages')
response(14, { notes = 'Durable note.', paths = {} })
wait_for(15)
values = plugin.get_settings()
values.personal_wiki.root = temp .. '/other-wiki'
assert(plugin.configure(values))
response(15, { pages = { page('notes/stale.md') } })
assert(vim.fn.filereadable(root .. '/notes/stale.md') == 0, 'root changes must invalidate pending writes')
plugin.send('No storage after switching chats.')
response(16, 'Done.')
wait_for(17)
plugin.new()
response(17, { notes = 'Stale chat.', queries = {} })
vim.wait(30, function() return false end, 5)
assert(#requests == 17)
plugin.send('Keep a new topic.')
response(18, 'Done.')
wait_for(19)
response(19, { notes = 'A new topic.', queries = { 'new topic' } })
wait_for(20)
input = vim.json.decode(requests[20].messages[2].content)
assert(#input.matches == 0 and input.catalog == nil)
response(20, { notes = 'A new topic.', paths = {} })
wait_for(21)
response(21, { pages = { page('notes/new-topic.md', '# New topic\nA new topic.\n') } })
assert(vim.fn.filereadable(temp .. '/other-wiki/notes/new-topic.md') == 1, 'no matches must still allow new pages')
plugin.send('Reject selecting an unmatched page.')
response(22, 'Done.')
wait_for(23)
response(23, { notes = 'A different topic.', queries = { 'no matches' } })
wait_for(24)
response(24, { notes = 'A different topic.', paths = { 'notes/new-topic.md' } })
vim.wait(30, function() return false end, 5)
assert(#requests == 24, 'unmatched pages must not be sent to the updater')
saved = history.load(history.workspace(), history.list(history.workspace())[1].id)
assert(saved.turn_costs[2].wiki_review.status == 'failed')
assert(saved.turn_costs[2].wiki_review.reason == 'wiki page was not in search results')
local new_file = temp .. '/other-wiki/notes/new-topic.md'
local new_preview = temp .. '/other-wiki/notes/.new-topic.md'
assert(table.concat(vim.fn.readfile(new_preview), '\n'):find('Summary of notes/new-topic.md', 1, true))
vim.fn.writefile({ '# Changed externally', 'New facts.' }, new_file)
vim.fn.mkdir(temp .. '/other-wiki/imported', 'p')
vim.fn.writefile({ '# Imported', 'Previously missing summary.' }, temp .. '/other-wiki/imported/page.md')
plugin.send('Refresh external edits before reviewing.')
response(25, 'Done.')
wait_for(26)
input = vim.json.decode(requests[26].messages[2].content)
assert(input.turn == nil and #input.pages == 2, 'stale and missing summaries must be refreshed first')
assert(input.pages[1].path == 'imported/page.md' and input.pages[2].content:find('New facts.', 1, true))
response(26, { pages = {
  { path = 'imported/page.md', summary = 'Imported information.' },
  { path = 'notes/new-topic.md', summary = 'Externally changed facts.' },
} })
wait_for(27)
assert(vim.fn.filereadable(temp .. '/other-wiki/imported/.page.md') == 1)
response(27, { notes = 'New facts.', queries = { 'externally' } })
wait_for(28)
input = vim.json.decode(requests[28].messages[2].content)
assert(#input.matches == 1 and input.matches[1].preview == 'Externally changed facts.')
response(28, { notes = '', paths = {} })
assert(table.concat(vim.fn.readfile(new_file), '\n') == '---\ntitle: "Changed externally"\ntags: []\naliases: []\n---\n\nNew facts.',
  'review must migrate the title while preserving external body content')
vim.fn.delete(temp, 'rf')
print('personal wiki tests passed')
