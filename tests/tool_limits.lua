vim.opt.runtimepath:prepend(vim.fn.getcwd())
local requests, callbacks, executed = {}, {}, {}
package.loaded['codeit.providers'] = {
  chat = function(config, messages, _, callback)
    requests[#requests + 1] = { config = config, messages = vim.deepcopy(messages) }
    callbacks[#callbacks + 1] = callback
  end,
}
local tools = require('codeit.tools')
tools.execute = function(name, _, _, callback)
  executed[#executed + 1] = name
  callback('Completed ' .. name)
end
local plugin = require('codeit')
local history = require('codeit.history')
local function reply(message)
  local callback = table.remove(callbacks, 1)
  assert(callback, 'missing provider callback')
  callback(message)
end
local function batch(prefix)
  local calls = {}
  for i = 1, 2 do
    calls[i] = { id = prefix .. i, type = 'function',
      ['function'] = { name = 'read_file', arguments = '{"path":"README.md"}' } }
  end
  return { role = 'assistant', tool_calls = calls }
end
local function assert_balanced(messages)
  local pending = {}
  for _, message in ipairs(messages) do
    if message.role ~= 'tool' then
      assert(next(pending) == nil, 'unmatched calls before the next message')
    end
    for _, call in ipairs(message.tool_calls or {}) do pending[call.id] = true end
    if message.role == 'tool' then
      assert(pending[message.tool_call_id], 'unexpected tool result')
      pending[message.tool_call_id] = nil
    end
  end
  assert(next(pending) == nil, 'unmatched calls at end of conversation')
end

for _, limit in ipairs({ 0, 1 }) do
  plugin.setup({ provider = 'openrouter', max_tool_rounds = limit, max_context_tokens = false })
  plugin.send('Keep using tools')
  local id = history.list(history.workspace())[1].id
  local before = #executed
  if limit == 1 then
    reply(batch('completed'))
    assert(#executed == before + 2, 'the allowed batch must execute')
    assert(#callbacks == 1, 'completed batch must request a follow-up')
  end
  local before_limit = #executed
  reply(batch('blocked'))
  assert(#executed == before_limit, 'the over-limit batch must not execute')
  assert(#callbacks == 0, 'the limit must stop further requests')
  local saved = history.load(history.workspace(), id)
  assert_balanced(saved.messages)
  assert(#saved.messages == 2 + limit * 3, 'only completed batches should be saved')
  plugin.send('Continue after the limit')
  local followup = requests[#requests].messages
  assert_balanced(followup)
  assert(#followup == #saved.messages + 1, 'continuing must preserve completed batches')
  assert(followup[#followup].content == 'Continue after the limit')
  reply({ role = 'assistant', content = 'Recovered.' })
  assert(plugin.resume(id))
  plugin.send('Continue after resuming')
  assert_balanced(requests[#requests].messages)
  reply({ role = 'assistant', content = 'Still recovered.' })
end

-- A normal assistant response at the boundary is allowed.
plugin.setup({ max_tool_rounds = 0, max_context_tokens = false })
plugin.send('No tools needed')
reply({ role = 'assistant', content = 'Finished without tools.' })
local saved = history.list(history.workspace())[1]
assert(saved.messages[#saved.messages].content == 'Finished without tools.')
print('codeit tool limit tests passed')
