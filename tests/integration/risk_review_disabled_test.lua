vim.opt.runtimepath:prepend(vim.fn.getcwd())
local requests, responses = {}, {}
package.loaded['codeit.providers'] = {
  chat = function(config, messages, specs, callback)
    requests[#requests + 1] = { config = config, messages = vim.deepcopy(messages), specs = specs }
    responses[#responses + 1] = callback
  end,
}
local function reply(message)
  local callback = table.remove(responses, 1)
  assert(callback, 'missing provider callback')
  callback(message)
end
local call_id = 0
local function call(name, arguments)
  call_id = call_id + 1
  return { id = name .. call_id, type = 'function', ['function'] = { name = name, arguments = vim.json.encode(arguments) } }
end
local source = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(source, vim.fn.getcwd() .. '/test.lua')
vim.api.nvim_buf_set_lines(source, 0, -1, false, { 'before' })
local plugin = require('codeit')
plugin.setup({ max_context_tokens = false, context_review = false, approval = {
  tool_call_risk = 'disabled', read_commands = { { argv = { 'inspect' } } },
} })
plugin.open()
plugin.send('Inspect and propose an edit')
assert(#requests == 1)
for _, definition in ipairs(requests[1].specs) do
  local parameters = definition['function'].parameters
  assert(parameters.properties.summary and vim.tbl_contains(parameters.required, 'summary'))
  assert(parameters.properties.risk_score == nil and parameters.properties.is_write == nil)
end
local runs = 0
require('codeit.process').run = function(_, _, callback)
  runs = runs + 1
  callback({ code = 0, stdout = 'inspected', stderr = '' })
end
reply({ role = 'assistant', tool_calls = {
  call('read_source_buffer', { summary = 'Read the source.' }),
  call('run_command', { argv = { 'inspect' }, summary = 'Inspect the project.' }),
  call('run_command', { argv = { 'inspect' } }),
} })
assert(vim.wait(2000, function() return #requests >= 2 end))
assert(#requests == 2 and #responses == 1 and runs == 1, 'no assessment request should be made')
local messages = requests[2].messages
assert(messages[#messages - 2].content:find('before', 1, true))
assert(messages[#messages - 1].content:find('inspected', 1, true))
assert(messages[#messages].content:find('missing argument summary', 1, true))
local writes = require('codeit.tools.approval.write')
local preview, choose
writes.show = function(diff, _, callback) preview, choose = diff, callback end
reply({ role = 'assistant', tool_calls = {
  call('edit_source_buffer', { summary = 'Change the source.', edits = { { old_text = 'before', new_text = 'after' } } }),
} })
assert(vim.wait(2000, function() return choose ~= nil end))
assert(preview.before == 'before\n' and preview.after == 'after\n')
assert(#requests == 2 and #responses == 0)
choose('once')
assert(vim.wait(2000, function() return #requests == 3 end))
assert(vim.api.nvim_buf_get_lines(source, 0, -1, false)[1] == 'after')
choose, preview = nil, nil
reply({ role = 'assistant', tool_calls = {
  call('save_source_buffer', { summary = 'Save all source changes.' }),
} })
assert(vim.wait(2000, function() return choose ~= nil end))
assert(preview ~= nil and #requests == 3 and #responses == 0, 'saving must still require explicit approval')
choose(nil)
assert(vim.wait(2000, function() return #requests == 4 end))
assert(vim.bo[source].modified, 'rejecting save must leave changes unsaved')
reply({ role = 'assistant', content = 'Done.' })
assert(#requests == 4 and #responses == 0)
print('integration risk_review_disabled_test: ok')
