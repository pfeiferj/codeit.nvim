vim.opt.runtimepath:prepend(vim.fn.getcwd())
local responses = {}
local requests = {}
package.loaded['codeit.providers'] = {
  chat = function(config, messages, specs, callback)
    table.insert(requests, { config = config, messages = vim.deepcopy(messages), specs = specs })
    table.insert(responses, callback)
  end,
}

local function reply(message)
  local callback = table.remove(responses, 1)
  assert(callback, 'missing callback')
  callback(message)
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
plugin.send('Show me the buffer')
assert(requests[1].messages[2].content == 'Show me the buffer')
tool_reply('read_buffer', { start_line = 1, end_line = 1 })
assert(#requests == 2)
assert(requests[2].messages[4].role == 'tool')
assert(requests[2].messages[4].content:find('before', 1, true))
reply({ role = 'assistant', content = 'Here is your buffer.' })
contains(vim.fn.bufnr('codeit://chat'), 'Here is your buffer.')

local select_callback
vim.ui.select = function(_, _, callback) select_callback = callback end
plugin.send('Change it')
tool_reply('replace_buffer_lines', {
  start_line = 1, end_line = 1, expected_text = 'before', new_text = 'after',
})
assert(select_callback)
assert(first_line(file) == 'before')
select_callback('Approve once')
assert(first_line(file) == 'after')
reply({ role = 'assistant', content = 'Done.' })

plugin.send('Another change')
tool_reply('replace_buffer_lines', {
  start_line = 1, end_line = 1, expected_text = 'after', new_text = 'oops',
})
plugin.new()
select_callback('Approve once')
assert(first_line(file) == 'after', 'reset must cancel pending edit')
local selections, questions = {}, {}
vim.ui.select = function(options, _, callback)
  local choice = table.remove(selections, 1)
  assert(vim.tbl_contains(options, choice), 'missing choice ' .. tostring(choice))
  callback(choice)
end
vim.ui.input = function(_, callback) callback(table.remove(questions, 1)) end
plugin.send('Check command')
selections = { 'Ask reviewer', 'Back to approval', 'Reject' }
questions = { 'What will happen?', 'Do not run it' }
tool_reply('run_command', { argv = { 'echo', 'test' } })
assert(#requests[#requests].specs == 0, 'reviewer must not receive tools')
reply({ role = 'assistant', content = 'It prints test.' })
assert(requests[#requests].specs == requests[1].specs, 'main chat must retain tools')
-- Rejection goes into the main tool result, not into the reviewer history.
assert(#responses == 1)
reply({ role = 'assistant', content = 'Understood.' })
assert(requests[#requests].messages[#requests[#requests].messages].content:find('Do not run it', 1, true))
plugin.send('Cancel this task')
selections = { 'Cancel task' }
tool_reply('run_command', { argv = { 'echo', 'cancel' } })

contains(vim.fn.bufnr('codeit://chat'), 'Task cancelled')
plugin.send('Continue after cancellation')
assert(requests[#requests].messages[#requests[#requests].messages].content == 'Continue after cancellation')
plugin.close()
print('codeit headless tests passed')
