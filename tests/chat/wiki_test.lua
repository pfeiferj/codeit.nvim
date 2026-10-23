vim.opt.runtimepath:prepend(vim.fn.getcwd())
local temp = vim.fn.tempname()
vim.fn.mkdir(temp, 'p')
vim.fn.chdir(temp)
local wiki = require('codeit.wiki')
local root = temp .. '/wiki'
local function page(path, content) return { path = path, content = content or '# Editor\n\nUses Neovim.\n' } end
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
local store = snapshot()
assert(wiki.apply(store, { page('preferences/editor.md') }))
store = snapshot()
assert(not wiki.apply(store, { page('preferences/editor.md', '# Changed\n') }), 'must read a page before replacing it')
assert(wiki.select(store, { 'preferences/editor.md' }))
assert(not wiki.select(store, { 'missing/page.md' }))
assert(not wiki.select(store, { 'preferences/editor.md', 'preferences/editor.md' }))
assert(not wiki.apply(store, { page('preferences/editor.md'), page('../escape.md') }))
assert(not wiki.apply(store, { page('notes/bad.md', 'not Markdown') }))
assert(not wiki.apply(store, { page('notes/big.md', '# Big\n' .. string.rep('x', 32768)) }))
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
assert(input.turn[1].content == 'I use Neovim for editing.' and #input.catalog >= 1)
plugin.send('My second turn while the review runs.')
assert(#requests == 4, 'wiki must not block the main agent')
response(3, { notes = 'User uses Neovim for editing.', paths = { 'preferences/editor.md' } })
wait_for(5)
input = vim.json.decode(requests[5].messages[2].content)
assert(input.pages[1].content:find('User edit.', 1, true), 'selected page contents must be read')
response(4, 'Second turn completed.')
assert(#requests == 5, 'reviews must serialize')
response(5, { pages = { page('preferences/editor.md', '# Editor\n\nUser edit.\n\nUses Neovim.\n') } })
wait_for(6)
assert(table.concat(vim.fn.readfile(filename), '\n'):find('Uses Neovim.', 1, true))
local saved = history.load(history.workspace(), history.list(history.workspace())[1].id)
assert(saved.cost_by_function.personal_wiki.requests == 2)
assert(saved.turn_costs[1].cost_by_function.personal_wiki.requests == 2)
assert(not saved.turn_costs[2].cost_by_function.personal_wiki)
response(6, { notes = '', paths = {} })
vim.wait(30, function() return false end, 5)
assert(#requests == 6, 'nothing worth retaining needs no update request')
plugin.send('Do not persist after I disable this feature.')
response(7, 'Done.')
wait_for(8)
values = plugin.get_settings()
values.personal_wiki.enabled = false
assert(plugin.configure(values))
response(8, { notes = 'A stale note.', paths = {} })
vim.wait(30, function() return false end, 5)
assert(#requests == 8, 'disabling must stop in-flight updates')
values.personal_wiki.enabled = true
assert(plugin.configure(values))
plugin.send('An invalid response should not wedge the queue.')
response(9, 'Done.')
wait_for(10)
response(10, 'not JSON')
plugin.send('Try another review.')
response(11, 'Done.')
wait_for(12)
response(12, { notes = 'Durable note.', paths = {} })
wait_for(13)
values = plugin.get_settings()
values.personal_wiki.root = temp .. '/other-wiki'
assert(plugin.configure(values))
response(13, { pages = { page('notes/stale.md') } })
assert(vim.fn.filereadable(root .. '/notes/stale.md') == 0, 'root changes must invalidate pending writes')
plugin.send('No storage after switching chats.')
response(14, 'Done.')
wait_for(15)
plugin.new()
response(15, { notes = 'Stale chat.', paths = {} })
vim.wait(30, function() return false end, 5)
assert(#requests == 15)
vim.fn.delete(temp, 'rf')
print('personal wiki tests passed')
