vim.opt.runtimepath:prepend(vim.fn.getcwd())
local requests = {}
package.loaded['codeit.providers'] = {
  chat = function(_, messages, _, callback, stream, active)
    requests[#requests + 1] = {
      messages = vim.deepcopy(messages), reply = callback, stream = stream, active = active,
    }
  end,
}
local plugin = require('codeit')
plugin.setup({ context_review = false, max_context_tokens = false })
local agents = require('codeit.tools.subagents')
vim.ui.select = function() error('subagent notifications must not prompt') end
local function call(title)
  return { id = title, type = 'function', ['function'] = {
    name = 'start_subagent', arguments = vim.json.encode({
      title = title, task = 'Inspect', mode = 'background_notify',
    }),
  } }
end
local function await(count)
  assert(vim.wait(1000, function() return #requests >= count end))
end
local function answer(index, text)
  requests[index].reply({ role = 'assistant', content = text })
end

plugin.send('Delegate and keep working')
requests[1].reply({ role = 'assistant', tool_calls = { call('First'), call('Second') } })
await(4)
requests[2].stream('Work in progress')
answer(3, 'First findings')
assert(#requests == 4 and requests[2].active(), 'completion must not cancel an active response')
assert(agents.list()[1].notification == 'pending')
vim.wait(250, function() return false end)
assert(#requests == 4, 'notification timer must not deliver during a round')
answer(2, 'Finished current round')
assert(#requests == 5 and agents.list()[1].notification == 'sent')
local messages = requests[5].messages
assert(messages[#messages].role == 'user' and messages[#messages].content:find('First findings', 1, true))
assert(messages[#messages - 1].content == 'Finished current round', 'retain the complete response, not its partial stream')
answer(4, 'Second findings')
assert(#requests == 5 and requests[5].active(), 'another result must wait for the next boundary')
assert(agents.list()[2].notification == 'pending')
answer(5, 'Finished another round')
assert(#requests == 6 and agents.list()[2].notification == 'sent')
assert(requests[6].messages[#requests[6].messages].content:find('Second findings', 1, true))
answer(6, 'Done')
vim.wait(250, function() return false end)
assert(#requests == 6, 'round-boundary results must only be delivered once')

plugin.send('Delegate and finish before the result')
requests[7].reply({ role = 'assistant', tool_calls = { call('Later') } })
await(9)
answer(8, 'Initial turn finished')
plugin.send('A different turn')
answer(9, 'Late findings')
assert(#requests == 10 and requests[10].active(), 'completion must not interrupt a later turn')
vim.wait(250, function() return false end)
assert(#requests == 10 and agents.list()[3].notification == 'pending')
answer(10, 'Later turn finished')
await(11)
assert(requests[11].messages[#requests[11].messages].content:find('Late findings', 1, true))
assert(agents.list()[3].notification == 'sent')
answer(11, 'Follow-up received')

plugin.send('Delegate before switching chats')
requests[12].reply({ role = 'assistant', tool_calls = { call('Other chat') } })
await(14)
plugin.new()
plugin.send('Keep this chat running')
answer(14, 'Other chat findings')
vim.wait(250, function() return false end)
assert(#requests == 15 and requests[15].active(), 'completion must not interrupt another chat')
answer(15, 'Done here')
vim.wait(250, function() return false end)
assert(#requests == 15, 'completion must not send results to another idle chat')
assert(agents.list()[4].notification == 'pending')
answer(13, 'Stale old-chat response')
assert(#requests == 15)
plugin.new()
local tools = require('codeit.tools')
local execute, finish_tool = tools.execute
local second_tool_ran = false
tools.execute = function(name, args, source, done, ...)
  if name == 'list_workspace_files' then finish_tool = done; return end
  if name == 'list_buffers' then second_tool_ran = true; return done('Second tool result') end
  return execute(name, args, source, done, ...)
end
plugin.send('Delegate while completing a tool batch')
requests[16].reply({ role = 'assistant', tool_calls = {
  call('Batch findings'),
  { id = 'held-tool', type = 'function', ['function'] = { name = 'list_workspace_files', arguments = '{}' } },
  { id = 'second-tool', type = 'function', ['function'] = { name = 'list_buffers', arguments = '{}' } },
} })
await(17)
answer(17, 'Findings during tools')
assert(#requests == 17 and agents.list()[5].notification == 'pending' and finish_tool)
vim.wait(250, function() return false end)
assert(#requests == 17 and not second_tool_ran, 'completion must not skip or cancel tools')
finish_tool('First tool result')
assert(#requests == 18 and second_tool_ran and agents.list()[5].notification == 'sent')
messages = requests[18].messages
assert(messages[#messages - 2].tool_call_id == 'held-tool' and messages[#messages - 2].content == 'First tool result')
assert(messages[#messages - 1].tool_call_id == 'second-tool' and messages[#messages - 1].content == 'Second tool result')
assert(messages[#messages].content:find('Findings during tools', 1, true))
answer(18, 'Batch done')
tools.execute = execute
agents.shutdown()
print('codeit subagent notification tests passed')
