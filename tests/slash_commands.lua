vim.opt.runtimepath:prepend(vim.fn.getcwd())
local slash = require('codeit.slash_commands')
local requests, responses = {}, {}
package.loaded['codeit.providers'] = {
  chat = function(_, messages, _, callback)
    requests[#requests + 1] = vim.deepcopy(messages)
    responses[#responses + 1] = callback
  end,
}
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
vim.api.nvim_feedkeys(vim.keycode('<C-g>'), 'x', false)
assert(vim.api.nvim_win_get_config(0).relative == 'editor', 'slash commands and LLM turns should work in the chat popup')
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

local function submit(text)
  set_draft(text)
  vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
end
local function assert_order(...)
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
  local previous = 0
  for _, value in ipairs({ ... }) do
    local position = text:find(value, previous + 1, true)
    assert(position, 'missing or out-of-order transcript entry: ' .. value)
    previous = position
  end
end

-- Commands before, between, and during turns stay where they ran, even when
-- later messages arrive or the conversation is saved and resumed.
submit('first question')
responses[#responses]({ role = 'assistant', content = 'first answer' })
submit('/trustStatus')
submit('/contextFull')
vim.cmd('close')
submit('second question')
submit('/trustStatus') -- Also works while a response is pending.
responses[#responses]({ role = 'assistant', content = 'second answer' })
assert_order('## Command: `/trustStatus`', 'first question', 'first answer',
  '## Command: `/trustStatus`', '## Command: `/contextFull`', 'second question',
  '## Command: `/trustStatus`', 'second answer', '## Message')
assert(#requests == 2, 'display-only commands must not request an LLM response')
assert(#requests[2] == 4 and requests[2][4].content == 'second question',
  'command output must not be sent to the assistant')
local history = require('codeit.history')
local saved = history.list(history.workspace())[1]
assert(#saved.command_results == 6, 'command results should be saved separately from messages')
local expected_anchors = { 0, 0, 0, 3, 3, 4 }
for i, result in ipairs(saved.command_results) do
  assert(result.after_message == expected_anchors[i], 'command should retain its message boundary')
end
ui.close()
codeit.open()
assert_order('first answer', '## Command: `/trustStatus`', 'second question',
  '## Command: `/trustStatus`', 'second answer')
codeit.new()
assert(not table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'):find('## Command:', 1, true),
  'new conversations should clear command results')
assert(codeit.resume(saved.id))
assert_order('## Command: `/trustStatus`', 'first question', 'first answer',
  '## Command: `/trustStatus`', '## Command: `/contextFull`', 'second question',
  '## Command: `/trustStatus`', 'second answer', '## Message')

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
