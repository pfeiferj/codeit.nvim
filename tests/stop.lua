vim.opt.runtimepath:prepend(vim.fn.getcwd())
local requests, pending = {}, {}
package.loaded['codeit.providers'] = { chat = function(_, messages, _, callback, on_text, active)
  requests[#requests + 1] = vim.deepcopy(messages)
  pending[#pending + 1] = { reply = callback, text = on_text, active = active }
end }
local codeit = require('codeit')
codeit.setup({ max_context_tokens = false, context_review_min_tokens = 100000 })
assert(not codeit.stop(), 'stopping an idle chat should be a no-op')
codeit.send('First question')
local first = pending[#pending]
first.text('Partial answer')
vim.cmd('CodeitStop')
assert(not first.active())
assert(not codeit.stop())
codeit.send('Follow up')
local follow = pending[#pending]
local kept_preview = false
for _, message in ipairs(requests[#requests]) do
  if message.role == 'assistant' and message.content == 'Partial answer' then kept_preview = true end
end
assert(kept_preview, 'keep streamed text')
first.text('Stale preview')
first.reply({ role = 'assistant', content = 'Stale answer' })
follow.reply({ role = 'assistant', content = 'Fresh answer' })
assert(not codeit.stop(), 'late callbacks must not revive the stopped turn')

local tools = require('codeit.tools')
local execute = tools.execute
local tool_done, tool_active, executed = nil, nil, 0
tools.execute = function(_, _, _, done, active)
  executed = executed + 1
  if executed == 1 then done('Completed result')
  else tool_done, tool_active = done, active end
end
local function call(id)
  return { id = id, type = 'function', ['function'] = { name = 'read_file', arguments = '{"path":"README.md"}' } }
end
codeit.send('Use tools')
pending[#pending].reply({ role = 'assistant', tool_calls = { call('done'), call('pending'), call('remaining') } })
assert(executed == 2 and tool_active())
codeit.open()
local ui = require('codeit.ui')
local peek = ui.peek_input
ui.peek_input = function() return '/stop' end
codeit.send()
ui.peek_input = peek
assert(not tool_active())
tool_done('Late result')
assert(executed == 2, 'remaining calls must not execute')
codeit.send('Continue after interruption')
local messages = requests[#requests]
local results = {}
for _, message in ipairs(messages) do
  if message.role == 'tool' then results[message.tool_call_id] = message.content end
  assert(message.content ~= 'Stale answer' and message.content ~= 'Late result')
end
assert(results.done == 'Completed result', 'preserve completed tool results')
assert(results.pending:find('Interrupted by user', 1, true))
assert(results.remaining:find('Interrupted by user', 1, true))
pending[#pending].reply({ role = 'assistant', content = 'Done' })
tools.execute = execute
assert(select(1, require('codeit.commands.slash').parse('/stop')).command == 'CodeitStop')
print('codeit stop tests passed')
