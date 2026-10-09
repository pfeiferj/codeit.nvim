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
plugin.setup({ provider = 'openrouter' })
plugin.open()
contains(vim.fn.bufnr('codeit://chat'), 'Cost: $0.000 | In: 0m | Out: 0m | Context: —')
plugin.send('Show me the buffer')
assert(requests[1].messages[2].content == 'Show me the buffer')
local prompt_ui = require('codeit.approval_prompt')
local read_choice
prompt_ui.show = function(_, _, callback) read_choice = callback end
tool_reply('read_buffer', { start_line = 1, end_line = 1 })
assert(not read_choice and #requests[#requests].specs == 0)
reply({ role = 'assistant', content = '{"summary":"Reads the first line.","safe":true}' })
assert(read_choice, 'untrusted buffer reads must request approval')
read_choice('once')
assert(#requests == 3)
contains(vim.fn.bufnr('codeit://chat'), 'Cost: $0.000+ | In: 0m+ | Out: 0m+ | Context: —')
assert(requests[3].messages[4].role == 'tool')
assert(requests[3].messages[4].content:find('before', 1, true))
reply({ role = 'assistant', content = 'Here is your buffer.' },
  { cost = 0.000123, prompt_tokens = 120, completion_tokens = 30, total_tokens = 150 })
contains(vim.fn.bufnr('codeit://chat'), 'Here is your buffer.')
contains(vim.fn.bufnr('codeit://chat'), 'Cost: $0.000+ | In: 0m+ | Out: 0m+ | Context: 0.15k')

local write_ui = require('codeit.write_approval')
local select_callback, edit_diff
write_ui.show = function(diff, _, callback)
  select_callback = callback
  edit_diff = diff
end
plugin.send('Change it')
tool_reply('replace_buffer_lines', {
  start_line = 1, end_line = 1, expected_text = 'before', new_text = 'after',
})
assert(select_callback)
assert(edit_diff and edit_diff.before == 'before\nsecond\n' and edit_diff.after == 'after\nsecond\n',
  'replace_buffer_lines must preview the entire file')
assert(first_line(file) == 'before')
select_callback('once')
assert(first_line(file) == 'after')
reply({ role = 'assistant', content = 'Done.' })

plugin.send('Another change')
tool_reply('replace_buffer_lines', {
  start_line = 1, end_line = 1, expected_text = 'after', new_text = 'oops',
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
assert(#requests[#requests].specs == 0, 'reviewer must not receive tools')
reply({ role = 'assistant', content = '{"summary":"Prints test.","safe":true}' })
assert(#requests[#requests].specs == 0, 'follow-up reviewer must not receive tools')
reply({ role = 'assistant', content = 'It prints test.' },
  { cost = 0.000321, prompt_tokens = 40, completion_tokens = 10 })
reviewer_back()
contains(vim.fn.bufnr('codeit://chat'), 'Cost: $0.000+ | In: 0m+ | Out: 0m+ | Context: —')
assert(requests[#requests].specs == requests[1].specs, 'main chat must retain tools')
-- Rejection goes into the main tool result, not into the reviewer history.
assert(#responses == 1)
reply({ role = 'assistant', content = 'Understood.' },
  { cost = 0, prompt_tokens = 80, completion_tokens = 5 })
contains(vim.fn.bufnr('codeit://chat'), 'Cost: $0.000+ | In: 0m+ | Out: 0m+ | Context: 0.085k')
assert(requests[#requests].messages[#requests[#requests].messages].content:find('Do not run it', 1, true))
plugin.send('Cancel this task')
selections = { 'cancel' }
tool_reply('run_command', { argv = { 'echo', 'cancel' } })
reply({ role = 'assistant', content = '{"summary":"Prints cancel.","safe":true}' })

contains(vim.fn.bufnr('codeit://chat'), 'Task cancelled')
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
plugin.set_provider('copilot')
local function no_billing()
  local lines = table.concat(vim.api.nvim_buf_get_lines(vim.fn.bufnr('codeit://chat'), 0, -1, false), '\n')
  assert(not lines:find('Cost:', 1, true) and not lines:find('credits:', 1, true), 'Copilot must not show billing')
end
no_billing()
plugin.send('Copilot request')
reply({ role = 'assistant', content = 'OK' })
no_billing()
plugin.new()
no_billing()
plugin.close()
print('codeit headless tests passed')
