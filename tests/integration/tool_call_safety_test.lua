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
  tool_call_risk = true,
  read_commands = { { argv = { 'inspect' } } },
} })
plugin.open()
plugin.send('Inspect and propose an edit')
assert(#requests == 1)
for _, definition in ipairs(requests[1].specs) do
  local parameters = definition['function'].parameters
  for _, key in ipairs({ 'summary', 'risk_score', 'is_write' }) do
    assert(parameters.properties[key] and vim.tbl_contains(parameters.required, key))
  end
end
local runs = 0
local process = require('codeit.process')
local original_run = process.run
process.run = function(argv, _, callback)
  assert(vim.deep_equal(argv, { 'inspect' }))
  runs = runs + 1
  callback({ code = 0, stdout = 'inspected', stderr = '' })
end
reply({ role = 'assistant', tool_calls = {
  call('read_source_buffer', { summary = 'Reads the source.', risk_score = 1, is_write = false }),
  call('run_command', { argv = { 'inspect' }, summary = 'Inspects the project.', risk_score = 1, is_write = false }),
  call('run_command', { argv = { 'inspect' }, summary = 'Missing write flag.', risk_score = 1 }),
} })
assert(vim.wait(2000, function() return #requests >= 2 end))
assert(#requests == 2 and #responses == 1 and runs == 1, 'no secondary assessment request should be made')
local messages = requests[2].messages
assert(messages[#messages - 2].content:find('before', 1, true))
assert(messages[#messages - 1].content:find('inspected', 1, true))
assert(messages[#messages].content:find('missing argument is_write', 1, true))
local writes = require('codeit.tools.approval.write')
local original_show = writes.show
local preview, choose
writes.show = function(diff, _, callback) preview, choose = diff, callback end
reply({ role = 'assistant', tool_calls = {
  call('edit_source_buffer', { summary = 'Changes the source.', risk_score = 3, is_write = true,
    edits = { { old_text = 'before', new_text = 'after' } } }),
} })
assert(vim.wait(2000, function() return choose ~= nil end))
assert(preview.before == 'before\n' and preview.after == 'after\n')
assert(#requests == 2 and #responses == 0, 'write preview must not trigger an assessment')
choose('once')
assert(vim.wait(2000, function() return #requests == 3 end))
assert(vim.api.nvim_buf_get_lines(source, 0, -1, false)[1] == 'after')
reply({ role = 'assistant', content = 'Done.' })
assert(#requests == 3 and #responses == 0)
writes.show, process.run = original_show, original_run
print('integration tool_call_risk_test: ok')
