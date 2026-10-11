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
assert(select(1, slash.parse('/CONTEXT-files')).command == 'CodeitContextFiles')
assert(select(1, slash.parse('/system-prompt')).command == 'CodeitSystemPrompt')
assert(select(1, slash.parse('/trust-status')).command == 'CodeitTrustStatus')
assert(select(1, slash.parse('/help')).name == 'help')
assert(select(1, slash.parse('//compact')) == nil)
assert(slash.literal('//compact') == '/compact')
assert(slash.literal('//compact\nmore') == '//compact\nmore')
assert(select(2, slash.parse('/contex')):find('did you mean /context?', 1, true))
local provider = slash.parse('/provider')
assert(provider.required and slash.validate(provider, ''))
assert(slash.validate(provider, 'invalid'))
assert(not slash.validate(provider, 'copilot'))
assert(not slash.validate(slash.parse('/trust'), ''))
local choices, start_col, hint = slash.complete('/provider co')
assert(#choices == 1 and choices[1].word == 'copilot' and start_col == 10 and hint)
assert(#slash.complete('/TRUST-st') == 1)
for _, item in ipairs(slash.complete_items()) do
  assert(item.menu ~= '' and not item.menu:match('^:Codeit'), 'commands need useful descriptions')
end

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
local function hint_text()
  local ns = vim.api.nvim_get_namespaces().codeit_chat_ui
  local text = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    for _, line in ipairs(mark[4].virt_lines or {}) do
      for _, chunk in ipairs(line) do text[#text + 1] = chunk[1] end
    end
  end
  return table.concat(text, ' ')
end
assert(hint_text():find('Unknown command', 1, true), 'errors should appear beside the draft')
set_draft('/provider')
codeit.send()
assert(draft() == '/provider' and hint_text():find('Choose a provider', 1, true))
set_draft('/provider missing')
codeit.send()
assert(draft() == '/provider missing' and hint_text():find('choose openrouter or copilot', 1, true))
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

-- Navigate a visible palette without mutating the draft; Enter selects only.
local refresh = '<Cmd>lua require("codeit.ui").refresh_slash(true)<CR>'
local function palette()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local config = vim.api.nvim_win_get_config(win)
    if config.zindex == 150 then
      assert(not config.focusable, 'palette must not take focus from the draft')
      return win, vim.api.nvim_win_get_buf(win)
    end
  end
end
local palette_checked = false
_G.codeit_test_palette = function()
  local win, buffer = palette()
  assert(win, 'typing / should automatically show the palette')
  local lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
  assert(lines[1]:find('Toggle the chat', 1, true), 'palette should show descriptions')
  palette_checked = true
end
local function keys(text)
  vim.api.nvim_feedkeys(vim.keycode(text), 'xt', false)
end
set_draft('')
keys('A/<Cmd>doautocmd TextChangedI<CR><Cmd>lua vim.wait(20); codeit_test_palette()<CR><Esc><Esc>')
assert(palette_checked, 'the insert-mode palette check must complete successfully')
assert(draft() == '/' and not palette(), 'Escape closes the menu and preserves the draft')
set_draft('/co')
keys('A' .. refresh .. '<Tab><Esc><Esc>')
assert(draft() == '/co', 'navigation and dismissal must preserve the typed prefix')
set_draft('/co')
keys('A' .. refresh .. '<Tab><CR><Esc>')
assert(draft() == '/context', 'Enter selects the highlighted command without running it')
set_draft('/co')
keys('A' .. refresh .. '<Tab><S-Tab><CR><Esc>')
assert(draft() == '/compact', 'Shift-Tab navigates backwards')
set_draft('/co')
keys('A' .. refresh .. '<C-n><C-p><CR><Esc>')
assert(draft() == '/compact', 'Ctrl-N and Ctrl-P navigate the palette')
set_draft('/provider')
keys('A' .. refresh .. '<CR><Tab><CR><Esc>')
assert(draft() == '/provider copilot', 'arguments are a second selection, not execution')
set_draft('/send')
keys('A' .. refresh .. '<CR><Esc>')
assert(draft() == '/send', 'free-text argument command must not execute on selection')
assert(vim.api.nvim_get_current_line() == '/send ', 'argument commands insert a trailing space')

-- Help opens the searchable palette rather than sending an LLM message.
set_draft('/help')
codeit.send()
assert(draft() == '/', '/help should reopen command discovery')
vim.cmd('stopinsert')
ui.dismiss_slash()
set_draft('//compact')
codeit.send()
assert(requests[#requests][#requests[#requests]].content == '/compact', 'literal slash should reach the assistant')
responses[#responses]({ role = 'assistant', content = 'literal answer' })

local autocmds = vim.api.nvim_get_autocmds({ event = 'TextChangedI', buffer = buf })
assert(#autocmds == 1, 'chat should register exactly one palette update handler')
assert(vim.fn.maparg('<CR>', 'i', false, true).buffer == 1, 'chat should handle Enter in insert mode')
ui.close()
codeit.open()
assert(#vim.api.nvim_get_autocmds({ event = 'TextChangedI', buffer = buf }) == 1,
  'reopening the chat must not duplicate palette updates')
ui.close()
assert(not palette(), 'closing chat should close the palette')

-- A streaming render can move the draft while its palette is open.
local chat = ui.new({ floating = true, name = 'codeit://slash-test' })
local sends = 0
local _, isolated = chat.open(function() sends = sends + 1 end, function() chat.close() end)
chat.render({}, 'Ready', 'test', 'model')
local row = vim.api.nvim_buf_line_count(isolated)
vim.api.nvim_buf_set_lines(isolated, row - 1, -1, false, { '/co' })
_G.codeit_test_stream_palette = function()
  chat.refresh_slash(true)
  assert(palette(), 'isolated chat should have a palette')
  chat.render({ { role = 'assistant', content = 'streaming output' } }, 'Working', 'test', 'model')
  chat.accept_slash()
end
keys('A<Cmd>lua codeit_test_stream_palette()<CR><Esc>')
assert(chat.peek_input() == '/compact', 'selection must use the draft location after a render')
assert(sends == 0, 'selection must never execute a command')
keys('A<CR><Esc>')
assert(sends == 1, 'Enter with the menu closed should run the selected command')
chat.destroy()
assert(not palette(), 'destroying chat must close its palette')
_G.codeit_test_palette, _G.codeit_test_stream_palette = nil, nil
print('codeit slash command tests passed')
