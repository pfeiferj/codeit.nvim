vim.opt.runtimepath:prepend(vim.fn.getcwd())
local requests, callbacks = {}, {}
package.loaded['codeit.providers'] = {
  chat = function(config, messages, _, callback)
    requests[#requests + 1] = { config = vim.deepcopy(config), messages = vim.deepcopy(messages) }
    callbacks[#callbacks + 1] = callback
  end,
}
local function reply(message)
  local callback = table.remove(callbacks, 1)
  assert(callback, 'missing provider callback')
  callback(message)
end
local function call(name, arguments)
  return { role = 'assistant', tool_calls = { { id = name, type = 'function',
    ['function'] = { name = name, arguments = arguments } } } }
end
local function canonical_arguments(messages)
  for i = #messages, 1, -1 do
    if messages[i].tool_calls then return messages[i].tool_calls[1]['function'].arguments end
  end
  error('missing tool call in follow-up: ' .. vim.inspect(messages))
end
local plugin = require('codeit')
assert(not pcall(plugin.setup, { tool_json_healing = 'yes' }))
local source = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(source, 0, -1, false, { 'first', 'second' })
local tools = require('codeit.tools')
local assessed
require('codeit.tools.approval').prefetch = function(_, args) assessed = vim.deepcopy(args) end
local execute, executed = tools.execute, {}
tools.execute = function(name, args, ...)
  executed[#executed + 1] = { name = name, args = vim.deepcopy(args) }
  return execute(name, args, ...)
end
local setup = { context_review = false, max_context_tokens = false }
plugin.setup(setup)
plugin.open()
plugin.send('Read the first line')
reply(call('read_source_buffer', '```json\n{"start_line":1,"end_line":1,}\n```'))
assert(executed[#executed].args.start_line == 1)
assert(assessed.start_line == 1 and assessed.end_line == 1)
local followup = requests[#requests].messages
assert(followup[#followup].content:find('first', 1, true))
local canonical = canonical_arguments(followup)
assert(canonical:sub(1, 1) == '{' and vim.json.decode(canonical).start_line == 1)
reply({ role = 'assistant', content = 'Done' })
assert(#callbacks == 0, 'after first read')

-- The global setting is copied to the independently resolved subagent config.
plugin.send('Delegate')
reply(call('start_subagent', '{"title":"Read","task":"Read the source","mode":"wait"}'))
assert(vim.wait(1000, function() return requests[#requests].config.tool_json_healing == true end))
reply(call('read_source_buffer', '{"start_line":2,"end_line":2,}'))
assert(vim.wait(1000, function() return #callbacks > 0 end))
assert(executed[#executed].args.start_line == 2)
followup = requests[#requests].messages
assert(followup[#followup].content:find('second', 1, true))
assert(vim.json.decode(canonical_arguments(followup)).start_line == 2)
reply({ role = 'assistant', content = 'Found it' })
reply({ role = 'assistant', content = 'Delegation done' })
assert(#callbacks == 0, 'after delegation')

-- Healing never bypasses schema validation.
plugin.send('Bad arguments')
reply(call('read_source_buffer', '{"start_line":"not a number",}'))
followup = requests[#requests].messages
assert(followup[#followup].content:find('Error:', 1, true))
reply({ role = 'assistant', content = 'Retry needed' })
assert(#callbacks == 0, 'after invalid schema')

local available = pcall(function()
  assert(vim.system({ 'python3', '-I', '-c', 'import yaml' }):wait(1000).code == 0)
end)
if available then
  plugin.send('Read via YAML')
  reply(call('read_source_buffer', 'start_line: 1\nend_line: 1'))
  assert(executed[#executed].args.start_line == 1)
  followup = requests[#requests].messages
  assert(followup[#followup].content:find('first', 1, true))
  assert(vim.json.decode(canonical_arguments(followup)).start_line == 1)
  reply({ role = 'assistant', content = 'Done' })
end

-- Repaired calls still honor approval rejections.
local approval_args
require('codeit.tools.approval').setup({ validators = { function(name, args)
  if name == 'run_command' then approval_args = vim.deepcopy(args); return 'reject', 'test rejection' end
end } })
plugin.send('Check approval')
reply(call('run_command', '{"argv":["echo","must not run",],}'))
assert(approval_args and approval_args.argv[2] == 'must not run')
followup = requests[#requests].messages
assert(followup[#followup].content:find('Rejected', 1, true))
reply({ role = 'assistant', content = 'Rejected as expected' })

-- Explicitly disabling healing must not repair malformed arguments.
assert(#callbacks == 0, 'stale callbacks: ' .. #callbacks)
setup.tool_json_healing = false
plugin.close()
plugin.setup(setup)
plugin.open()
plugin.send('Read without healing')
reply(call('read_source_buffer', '{"start_line":1,}'))
assert(not executed[#executed].args, vim.inspect({ executed = executed[#executed], config = requests[#requests].config, pending = #callbacks }))
followup = requests[#requests].messages
assert(followup[#followup].content:find('Error:', 1, true))
reply({ role = 'assistant', content = 'Cannot read' })
assert(vim.api.nvim_buf_get_lines(source, 0, 1, false)[1] == 'first')
print('Tool JSON healing conversation and subagents: passed')
