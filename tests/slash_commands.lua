vim.opt.runtimepath:prepend(vim.fn.getcwd())
local slash = require('codeit.slash_commands')
local codeit = require('codeit')
local ui = require('codeit.ui')

local names = {}
for _, item in ipairs(slash.complete_items()) do names[item.word] = true end
for _, name in ipairs({ '/toggle', '/send', '/new', '/compact', '/context', '/contextFull', '/systemPrompt',
  '/history', '/trust', '/untrust', '/trustStatus', '/provider', '/contextFiles' }) do
  assert(names[name], 'missing completion: ' .. name)
end
assert(select(1, slash.parse('/compact')).command == 'CodeitCompact')
assert(select(1, slash.parse('/contextFull')).command == 'CodeitContextFull')
assert(select(1, slash.parse('/compact anything')) == false)
assert(select(1, slash.parse('/missing')) == false)
assert(select(1, slash.parse('/compact\nmore')) == nil)
assert(select(1, slash.parse('What about /compact?')) == nil)

codeit.setup()
codeit.open()
local buf = vim.fn.bufnr('codeit://chat')
local function draft()
  return ui.peek_input()
end
local function set_draft(text)
  local row = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_buf_set_lines(buf, row - 1, -1, false, { text })
  vim.api.nvim_win_set_cursor(0, { row, #text })
end

-- Run a command through the normal-mode draft submission path, not a direct API call.
set_draft('/new')
vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
assert(draft() == nil, 'successful slash command should clear its draft')
set_draft('/noSuchCommand')
vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
assert(draft() == '/noSuchCommand', 'unknown slash commands must remain editable')
set_draft('/provider copilot')
vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
assert(draft() == nil, 'argument-bearing slash command should execute')
assert(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]:find('copilot', 1, true))
set_draft('/contextFull')
vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
assert(vim.fn.bufwinid('codeit://context-full') ~= -1, 'camelCase command should open the editor')
vim.cmd('close')

set_draft('/trustStatus')
vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
local transcript = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
assert(transcript:find('## Command: `/trustStatus`', 1, true), 'slash command should appear in chat')
assert(transcript:find('codeit: ', 1, true), 'command notification should appear in chat')

-- The first Tab snapshots prefix matches; later Tabs cycle those matches even
-- though the inserted command no longer shares the original prefix.
set_draft('/co')
vim.api.nvim_feedkeys(vim.keycode('A<Tab><Esc>'), 'xt', false)
assert(draft() == '/compact', 'first Tab should complete the prefix: ' .. tostring(draft()))
set_draft('/co')
vim.api.nvim_feedkeys(vim.keycode('A<Tab><Tab><Esc>'), 'xt', false)
assert(draft() == '/context', 'second Tab should cycle the original matches: ' .. tostring(draft()))
set_draft('/co')
vim.api.nvim_feedkeys(vim.keycode('A<Tab><Tab><Tab><Esc>'), 'xt', false)
assert(draft() == '/contextFull', 'Tab should keep cycling: ' .. tostring(draft()))

set_draft('')
vim.api.nvim_feedkeys(vim.keycode('A/<Tab><Tab><Esc>'), 'xt', false)
assert(draft() == '/send', 'typing / then Tab should cycle from the initial menu: ' .. tostring(draft()))

-- Completion is buffer-local and InsertCharPre starts it as soon as '/' is typed.
local autocmds = vim.api.nvim_get_autocmds({ event = 'InsertCharPre', buffer = buf })
assert(#autocmds == 1, 'chat should register exactly one slash completion handler')
assert(vim.fn.maparg('<CR>', 'i', false, true).buffer == 1, 'chat should handle Enter in insert mode')
ui.close()
codeit.open()
assert(#vim.api.nvim_get_autocmds({ event = 'InsertCharPre', buffer = buf }) == 1,
  'reopening the chat must not duplicate slash completion')
ui.close()
print('codeit slash command tests passed')
