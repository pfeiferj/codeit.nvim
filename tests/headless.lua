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
assert(#requests[1].specs == 13)
reply({ role = 'assistant', content = vim.NIL, tool_calls = { {
  id = 'call1', type = 'function', ['function'] = { name = 'read_buffer', arguments = '{"start_line":1,"end_line":1}' },
} } })
assert(#requests == 2)
assert(requests[2].messages[4].role == 'tool')
assert(requests[2].messages[4].content:find('before', 1, true))
reply({ role = 'assistant', content = 'Here is your buffer.' })
contains(vim.fn.bufnr('codeit://chat'), 'Here is your buffer.')

local select_callback
vim.ui.select = function(_, _, callback) select_callback = callback end
plugin.send('Change it')
reply({ role = 'assistant', content = vim.NIL, tool_calls = { {
  id = 'call2', type = 'function', ['function'] = { name = 'replace_buffer_lines', arguments = vim.json.encode({
    start_line = 1, end_line = 1, expected_text = 'before', new_text = 'after',
  }) },
} } })
assert(select_callback)
assert(vim.api.nvim_buf_get_lines(file, 0, 1, false)[1] == 'before')
select_callback('Apply')
assert(vim.api.nvim_buf_get_lines(file, 0, 1, false)[1] == 'after')
reply({ role = 'assistant', content = 'Done.' })

plugin.send('Another change')
reply({ role = 'assistant', content = vim.NIL, tool_calls = { {
  id = 'call3', type = 'function', ['function'] = { name = 'replace_buffer_lines', arguments = vim.json.encode({
    start_line = 1, end_line = 1, expected_text = 'after', new_text = 'oops',
  }) },
} } })
plugin.new()
select_callback('Apply')
assert(vim.api.nvim_buf_get_lines(file, 0, 1, false)[1] == 'after', 'reset must cancel pending edit')
plugin.close()
print('codeit headless tests passed')
