vim.opt.runtimepath:prepend(vim.fn.getcwd())
local ui = require('codeit.ui')
ui.open(function() error('must not send') end, ui.close)
local win = vim.api.nvim_get_current_win()
local buf = vim.api.nvim_get_current_buf()
local call = { id = 'read', ['function'] = { name = 'read_file', arguments = '{}' } }
local reasoning = { { type = 'reasoning.text', text = 'Inspect the file first.' },
  { type = 'reasoning.summary', summary = 'A short summary.' },
  { type = 'reasoning.encrypted', data = 'SECRET ENCRYPTED DATA' } }
local messages = {
  { role = 'user', content = 'Request' },
  { role = 'assistant', reasoning_details = reasoning, tool_calls = { call } },
  { role = 'tool', tool_call_id = 'read', content = 'Short result' },
  { role = 'assistant', _copilot_reasoning = {
    { encrypted_content = 'SECRET REPLAY DATA', summary = { { type = 'summary_text', text = 'Ready to answer.' } } },
  }, content = 'Answer' },
  { role = 'user', content = 'Next request' },
}
local results = { { after_message = 3, command = 'CodeitTrustStatus', output = 'Trusted' } }
local function render(billing)
  ui.render(messages, 'Working', 'test', 'test', billing, results)
end
local function row(text)
  for index, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line == text then return index end
  end
  error('missing line: ' .. text)
end
local function toggle(line)
  vim.api.nvim_win_set_cursor(0, { line, 0 })
  vim.cmd('normal! za')
end
render()
local text = table.concat(ui.chat_lines(), '\n')
assert(text:find('Inspect the file first.\nA short summary.', 1, true))
assert(text:find('Ready to answer.', 1, true))
assert(not text:find('SECRET', 1, true), 'encrypted reasoning must never be displayed')
assert(reasoning[1].text == 'Inspect the file first.', 'rendering must not mutate reasoning')
local section = row('**Activity**')
local thought = row('**Reasoning**')
local input = row('*Calling `read_file`…*')
local output = row('**Tool: read_file**')
local command = row('## Command: `CodeitTrustStatus`')
for _, line in ipairs({ thought, input, output, command, row('Ready to answer.') }) do
  assert(vim.fn.foldclosed(line) == section, 'consecutive activity should share one outer fold')
  assert(vim.fn.foldlevel(line) == 2, 'each activity item should have an inner fold')
end
assert(vim.fn.foldtextresult(section):find('Activity · 5 items', 1, true))
for _, line in ipairs({ row('Request'), row('Answer'), row('Next request'), row('## Message') }) do
  assert(vim.fn.foldlevel(line) == 0, 'messages and draft must remain outside activity folds')
end
toggle(section)
for _, line in ipairs({ thought, input, output, command }) do
  assert(vim.fn.foldclosed(line) == line, 'opening the outer fold must leave inner folds collapsed')
end
toggle(thought)
assert(vim.fn.foldclosed(row('Inspect the file first.')) == -1)
assert(vim.fn.foldclosed(input) == input, 'reasoning should expand independently')
toggle(section)
render('New billing line')
section, thought, input = row('**Activity**'), row('**Reasoning**'), row('*Calling `read_file`…*')
assert(vim.fn.foldclosed(thought) == section, 'closed outer folds should survive renders')
toggle(section)
assert(vim.fn.foldclosed(thought) == -1, 'hidden inner expansion state should survive renders')
assert(vim.fn.foldclosed(input) == input)
-- Newly appended tool items default to closed without closing an expanded group.
table.insert(messages, 4, { role = 'tool', name = 'extra', content = 'New result' })
results[1].after_message = 4
render()
section, thought = row('**Activity**'), row('**Reasoning**')
assert(vim.fn.foldclosed(section) == -1 and vim.fn.foldclosed(thought) == -1)
assert(vim.fn.foldclosed(row('**Tool: extra**')) == row('**Tool: extra**'))
ui.toggle_popup()
assert(vim.fn.foldclosed(thought) == -1)
toggle(section)
ui.toggle_popup()
assert(vim.api.nvim_get_current_win() == win)
assert(vim.fn.foldclosed(thought) == section, 'outer state should transfer back from popup')
toggle(section)
assert(vim.fn.foldclosed(thought) == -1, 'popup switches should retain hidden child state')
-- Assistant prose splits activity into separate groups, even with tools in the same message.
messages = { { role = 'assistant', reasoning_details = vim.deepcopy(reasoning), content = 'Explanation', tool_calls = { call } },
  { role = 'tool', tool_call_id = 'read', content = 'Result' },
  { role = 'user', content = 'Follow-up' } }
results = nil
render()
local groups = {}
for index, line in ipairs(ui.chat_lines()) do
  if line == '**Activity**' then groups[#groups + 1] = index end
end
assert(#groups == 2)
assert(vim.fn.foldlevel(row('Explanation')) == 0 and vim.fn.foldlevel(row('Follow-up')) == 0)
assert(vim.fn.foldclosed(row('**Reasoning**')) == groups[1])
assert(vim.fn.foldclosed(row('*Calling `read_file`…*')) == groups[2])
ui.close()
vim.cmd('qa!')
