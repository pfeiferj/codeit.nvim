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
assert(#requests == 5, 'completion immediately resumes the originating turn')
assert(agents.list()[1].notification == 'sent')
assert(not requests[2].active(), 'interrupted provider request must become inactive')
local messages = requests[5].messages
assert(messages[#messages].role == 'user' and messages[#messages].content:find('First findings', 1, true))
assert(messages[#messages - 1].content == 'Work in progress', 'partial response must be preserved')
answer(2, 'Stale response')
assert(#requests == 5, 'stale callback must not finish the resumed turn')
answer(4, 'Second findings')
assert(#requests == 6 and not requests[5].active(), 'another result can interrupt the same resumed turn')
assert(agents.list()[2].notification == 'sent')
assert(requests[6].messages[#requests[6].messages].content:find('Second findings', 1, true))
answer(5, 'Another stale response')
answer(6, 'Done')
vim.wait(250, function() return false end)
assert(#requests == 6, 'immediate results must only be delivered once')

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
agents.shutdown()
print('codeit subagent notification tests passed')
