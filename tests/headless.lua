vim.opt.runtimepath:prepend(vim.fn.getcwd())
local responses = {}
local requests = {}
package.loaded['codeit.providers'] = {
  chat = function(config, messages, specs, callback)
    table.insert(requests, { config = config, messages = vim.deepcopy(messages), specs = specs })
    table.insert(responses, callback)
  end,
}

local function reply(message, usage)
  local callback = table.remove(responses, 1)
  assert(callback, 'missing callback')
  callback(message, nil, usage)
end

local function tool_reply(name, args)
  reply({ role = 'assistant', content = vim.NIL, tool_calls = { {
    id = name, type = 'function', ['function'] = { name = name, arguments = vim.json.encode(args) },
  } } })
end

local function first_line(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
end

local function contains(buf, text)
  local lines = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
  assert(lines:find(text, 1, true), 'missing ' .. text .. ' in ' .. lines)
end

local file = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(file, vim.fn.getcwd() .. '/test.lua')
vim.api.nvim_buf_set_lines(file, 0, -1, false, { 'before', 'second' })
local plugin = require('codeit')
plugin.setup({ provider = 'openrouter', model_presets = {
  fast = { model = 'review-model' }, reasoning = { model = 'review-model' },
} })
plugin.open()
contains(vim.fn.bufnr('codeit://chat'), 'Cost: $0.000 | In: 0m | Out: 0m | Context: —')
plugin.send('Show me the buffer')
assert(requests[1].messages[2].content == 'Show me the buffer')
assert(requests[1].config.model == 'openai/gpt-4o-mini', 'main requests use the main model')
local prompt_ui = require('codeit.approval_prompt')
local read_choice
prompt_ui.show = function(_, _, callback) read_choice = callback end
local reasoning = { { type = 'reasoning', id = 'rs_1', summary = {}, encrypted_content = 'encrypted' } }
reply({ role = 'assistant', content = vim.NIL, _copilot_reasoning = reasoning, tool_calls = { {
  id = 'read_source_buffer', type = 'function',
  ['function'] = { name = 'read_source_buffer', arguments = '{"start_line":1,"end_line":1}' },
} } })
assert(not read_choice, 'user-attached visible buffer reads must not request approval')
assert(#requests == 2, 'visible reads should immediately continue without a reviewer summary')
contains(vim.fn.bufnr('codeit://chat'), 'Cost: $0.000+ | In: 0m+ | Out: 0m+ | Context: —')
assert(vim.deep_equal(requests[2].messages[3]._copilot_reasoning, reasoning),
  'encrypted Copilot reasoning must survive the chat loop for tool follow-ups')
assert(requests[2].messages[4].role == 'tool')
assert(requests[2].messages[4].content:find('before', 1, true))
reply({ role = 'assistant', content = 'Here is your buffer.' },
  { cost = 0.000123, prompt_tokens = 120, completion_tokens = 30, total_tokens = 150 })
contains(vim.fn.bufnr('codeit://chat'), 'Here is your buffer.')
contains(vim.fn.bufnr('codeit://chat'), 'Cost: $0.000+ | In: 0m+ | Out: 0m+ | Context: 0.15k')

local chat_buf = vim.fn.bufnr('codeit://chat')
local bottom = vim.api.nvim_buf_line_count(chat_buf)
vim.api.nvim_buf_set_lines(chat_buf, bottom - 1, -1, false, { 'draft one', 'draft two' })
plugin.send()
assert(requests[#requests].messages[#requests[#requests].messages].content == 'draft one\ndraft two')
assert(vim.api.nvim_buf_get_lines(chat_buf, -2, -1, false)[1] == '', 'sending clears only the draft')
local waiting_bottom = vim.api.nvim_buf_line_count(chat_buf)
vim.api.nvim_buf_set_lines(chat_buf, waiting_bottom - 1, -1, false, { 'next draft' })
reply({ role = 'assistant', content = 'Draft received.' })
assert(vim.api.nvim_buf_get_lines(chat_buf, -2, -1, false)[1] == 'next draft',
  'async replies must preserve an unfinished draft')
assert(require('codeit.ui').take_input() == 'next draft')

local write_ui = require('codeit.write_approval')
local select_callback, edit_diff
write_ui.show = function(diff, _, callback)
  select_callback = callback
  edit_diff = diff
end
plugin.send('Change it')
tool_reply('edit_source_buffer', {
  edits = { { start_line = 1, end_line = 1, old_text = 'before', new_text = 'after' } },
})
assert(select_callback)
assert(edit_diff and edit_diff.before == 'before\nsecond\n' and edit_diff.after == 'after\nsecond\n',
  'edit_file must preview the entire file')
assert(first_line(file) == 'before')
select_callback('once')
assert(first_line(file) == 'after')
reply({ role = 'assistant', content = 'Done.' })

plugin.send('Another change')
tool_reply('edit_source_buffer', {
  edits = { { start_line = 1, end_line = 1, old_text = 'after', new_text = 'oops' } },
})
plugin.new()
contains(vim.fn.bufnr('codeit://chat'), 'Cost: $0.000 | In: 0m | Out: 0m | Context: —')
select_callback('once')
assert(first_line(file) == 'after', 'reset must cancel pending edit')
local selections, questions = {}, {}
prompt_ui.show = function(_, options, callback)
  local choice = table.remove(selections, 1)
  assert(vim.tbl_contains(vim.tbl_map(function(option) return option.id end, options), choice), 'missing choice ' .. tostring(choice))
  callback(choice)
end
local reviewer_back
prompt_ui.ask_reviewer = function(name, args, ask, back)
  assert(name == 'run_command' and args:find('echo', 1, true))
  reviewer_back = back
  ask(table.remove(questions, 1), function(answer) assert(answer == 'It prints test.') end)
end
vim.ui.input = function(_, callback) callback(table.remove(questions, 1)) end
plugin.send('Check command')
selections = { 'review', 'reject' }
questions = { 'What will happen?', 'Do not run it' }
tool_reply('run_command', { argv = { 'echo', 'test' } })
assert(#requests[#requests - 1].specs == 0, 'automatic assessments must not receive tools')
assert(requests[#requests - 1].config.model == 'review-model', 'tool assessments use the fast preset')
reply({ role = 'assistant', content = '{"summary":"Prints test.","safety_score":1}' })
assert(#requests[#requests].specs == 2, 'interactive reviewer must receive only history tools')
assert(requests[#requests].specs[1]['function'].name == 'read_chat_history')
assert(requests[#requests].specs[2]['function'].name == 'search_chat_history')
assert(requests[#requests].config.model == 'review-model', 'interactive reviewer uses the reasoning preset')
tool_reply('search_chat_history', { query = 'Check command' })
local review_messages = requests[#requests].messages
local matches = vim.json.decode(review_messages[#review_messages].content).matches
assert(#matches == 1 and matches[1].text == 'Check command')
tool_reply('read_chat_history', { start_line = matches[1].line_number, end_line = matches[1].line_number + 3 })
review_messages = requests[#requests].messages
assert(vim.json.decode(review_messages[#review_messages].content).lines[1] == 'Check command')
-- Unknown reviewer calls must never reach the main executor or create another approval.
tool_reply('run_command', { argv = { 'echo', 'must not execute' } })
review_messages = requests[#requests].messages
assert(review_messages[#review_messages].content:find('unknown reviewer tool', 1, true))
assert(#selections == 1, 'reviewer calls must not consume approval choices')
reply({ role = 'assistant', content = 'It prints test.' },
  { cost = 0.000321, prompt_tokens = 40, completion_tokens = 10 })
reviewer_back()
contains(vim.fn.bufnr('codeit://chat'), 'Cost: $0.000+ | In: 0m+ | Out: 0m+ | Context: —')
assert(vim.deep_equal(requests[#requests].specs, requests[1].specs), 'main chat must retain tools')
assert(requests[#requests].config.model == 'openai/gpt-4o-mini', 'main chat must retain its model after review')
-- Rejection goes into the main tool result, not into the reviewer history.
assert(#responses == 1)
reply({ role = 'assistant', content = 'Understood.' },
  { cost = 0, prompt_tokens = 80, completion_tokens = 5 })
contains(vim.fn.bufnr('codeit://chat'), 'Cost: $0.000+ | In: 0m+ | Out: 0m+ | Context: 0.085k')
contains(vim.fn.bufnr('codeit://chat'), '**You** · Turn cost: $0.000+')
local history = require('codeit.history')
local reviewed_chat = history.list(history.workspace())[1]
local reviewed_turn = reviewed_chat.turn_costs[#reviewed_chat.turn_costs]
assert(reviewed_chat.messages[reviewed_turn.first].content == 'Check command')
assert(reviewed_turn.cost == 0.000321 and reviewed_turn.missing_cost == 5,
  'a turn must include its main requests, assessment, and all interactive reviewer requests')
assert(reviewed_turn.cost_by_function.main_chat.requests == 2)
assert(reviewed_turn.cost_by_function.main_chat.missing_cost == 1)
assert(reviewed_turn.cost_by_function.tool_assessment.requests == 1)
assert(reviewed_turn.cost_by_function.tool_assessment.missing_cost == 1)
assert(reviewed_turn.cost_by_function.tool_review.requests == 4)
assert(reviewed_turn.cost_by_function.tool_review.missing_cost == 3)
assert(reviewed_turn.cost_by_function.tool_review.cost == 0.000321)
assert(reviewed_chat.cost_by_function.tool_review.cost == 0.000321)
assert(requests[#requests].messages[#requests[#requests].messages].content:find('Do not run it', 1, true))
for _, message in ipairs(requests[#requests].messages) do
  for _, call in ipairs(type(message.tool_calls) == 'table' and message.tool_calls or {}) do
    assert(call['function'].name ~= 'search_chat_history' and call['function'].name ~= 'read_chat_history',
      'reviewer history tools must not leak into the main transcript')
  end
end
plugin.send('Cancel this task')
selections = { 'cancel' }
tool_reply('run_command', { argv = { 'echo', 'cancel' } })
assert(#responses == 1, 'cancelled review response may still be in flight')
reply({ role = 'assistant', content = '{"summary":"Prints cancel.","safety_score":1}' })

local status_lines = {}
local ui_ns = vim.api.nvim_get_namespaces().codeit_chat_ui
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(chat_buf, ui_ns, 0, -1, { details = true })) do
  for _, line in ipairs(mark[4].virt_lines or {}) do
    for _, chunk in ipairs(line) do status_lines[#status_lines + 1] = chunk[1] end
  end
end
assert(table.concat(status_lines, '\n'):find('Task cancelled', 1, true),
  'cancellation status should appear in the virtual draft hint')
plugin.send('Continue after cancellation')
assert(requests[#requests].messages[#requests[#requests].messages].content == 'Continue after cancellation')
local stale = table.remove(responses, 1)
plugin.new()
stale({ role = 'assistant', content = 'late' }, nil, { cost = 9 })
contains(vim.fn.bufnr('codeit://chat'), 'Cost: $0.000 | In: 0m | Out: 0m | Context: —')
plugin.send('Count tokens')
reply({ role = 'assistant', content = 'Counted.' },
  { cost = 0, prompt_tokens = 2600000, completion_tokens = 1200000, total_tokens = 3800000 })
contains(vim.fn.bufnr('codeit://chat'), 'In: 2.6m | Out: 1.2m | Context: 3800k')
plugin.send('Check context')
reply({ role = 'assistant', content = 'Checked.' },
  { cost = 0, prompt_tokens = 80000, completion_tokens = 20000, total_tokens = 100000 })
contains(vim.fn.bufnr('codeit://chat'), 'In: 2.68m | Out: 1.22m | Context: 100k')
plugin.send('Check rounding')
reply({ role = 'assistant', content = 'Rounded.' },
  { cost = 1.23456, prompt_tokens = 1234, completion_tokens = 5678, total_tokens = 123456 })
contains(vim.fn.bufnr('codeit://chat'), 'Cost: $1.235 | In: 2.681m | Out: 1.226m | Context: 123.456k')
contains(vim.fn.bufnr('codeit://chat'), '**You** · Turn cost: $1.235')
contains(vim.fn.bufnr('codeit://chat'), '**You** · Turn cost: $0.000')
plugin.new()
local batch_prompts, batch_choices = {}, {}
prompt_ui.show = function(prompt, _, callback)
  local index = #batch_prompts + 1
  batch_prompts[index] = prompt
  batch_choices[index] = callback
  return function(updated) batch_prompts[index] = updated end
end
plugin.send('Run two commands')
reply({ role = 'assistant', tool_calls = {
  { id = 'first', type = 'function', ['function'] = { name = 'run_command', arguments = '{"argv":["echo","first"]}' } },
  { id = 'second', type = 'function', ['function'] = { name = 'run_command', arguments = '{"argv":["echo","second"]}' } },
} })
assert(#responses == 2 and #batch_prompts == 1, 'both summaries must start before the first approval is decided')
assert(batch_prompts[1]:find('Waiting for provider…', 1, true))
assert(requests[#requests].messages[2].content:find('second', 1, true), 'second call review must start immediately')
reply({ role = 'assistant', content = '{"summary":"First command.","safety_score":1}' })
assert(batch_prompts[1]:find('Summary: First command.', 1, true))
reply({ role = 'assistant', content = '{"summary":"Second command.","safety_score":1}' })
batch_choices[1]('reject')
assert(#batch_prompts == 2 and batch_prompts[2]:find('Summary: Second command.', 1, true))
batch_choices[2]('reject')
assert(#responses == 1, 'batch should return to main provider only after both decisions')
reply({ role = 'assistant', content = 'Commands rejected.' })
plugin.set_provider('copilot')
contains(vim.fn.bufnr('codeit://chat'), 'Cost: $0.000 | In: 0m | Out: 0m | Context: —')
plugin.send('Copilot request')
reply({ role = 'assistant', content = 'OK' },
  { cost = 0.012, prompt_tokens = 1200000, completion_tokens = 500000, total_tokens = 1700000 })
contains(vim.fn.bufnr('codeit://chat'), 'Cost: $0.012 | In: 1.2m | Out: 0.5m | Context: 1700k')
plugin.send('Copilot follow-up')
reply({ role = 'assistant', content = 'OK again' },
  { cost = 0, prompt_tokens = 100000, completion_tokens = 20000, total_tokens = 120000 })
contains(vim.fn.bufnr('codeit://chat'), 'Cost: $0.012 | In: 1.3m | Out: 0.52m | Context: 120k')
plugin.send('Missing Copilot usage')
reply({ role = 'assistant', content = 'Unknown usage' })
contains(vim.fn.bufnr('codeit://chat'), 'Cost: $0.012+ | In: 1.3m+ | Out: 0.52m+ | Context: —')
plugin.new()
contains(vim.fn.bufnr('codeit://chat'), 'Cost: $0.000 | In: 0m | Out: 0m | Context: —')
plugin.close()
print('codeit headless tests passed')
