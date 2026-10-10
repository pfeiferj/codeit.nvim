vim.opt.runtimepath:prepend(vim.fn.getcwd())
local requests, callbacks, executed = {}, {}, {}
package.loaded['codeit.providers'] = {
  chat = function(config, messages, specs, callback, on_text)
    requests[#requests + 1] = { config = config, messages = vim.deepcopy(messages), specs = specs, on_text = on_text }
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
local prompts, pending, input = {}, nil, nil
require('codeit.approval_prompt').show = function(text, options, cb, config)
  assert(text:find('Tool limit reached', 1, true) and config.dismiss == 'Decline additional tools')
  prompts[#prompts + 1] = options
  assert(not pending, 'only one limit decision may be pending')
  pending = cb
end
vim.ui.input = function(opts, cb)
  assert(opts.prompt == 'Additional tool rounds: ')
  input = cb
end
local function choose(choice)
  local cb = pending
  assert(cb, 'missing limit prompt')
  pending = nil
  cb(choice)
end
local function enter(value)
  local cb = input
  assert(cb, 'missing custom allowance prompt')
  input = nil
  cb(value)
end
local function reply(message)
  local callback = table.remove(callbacks, 1)
  assert(callback, 'missing provider callback')
  callback(message)
end
local reasoning = { { type = 'reasoning', id = 'rs_limit', summary = {}, encrypted_content = 'encrypted-limit' } }
local reasoning_details = { { type = 'reasoning.encrypted', id = 'or_limit', data = 'encrypted-openrouter' } }
local function batch(prefix)
  local calls = {}
  for i = 1, 2 do
    calls[i] = { id = prefix .. i, type = 'function',
      ['function'] = { name = 'read_file', arguments = '{"path":"README.md"}' } }
  end
  return { role = 'assistant', tool_calls = calls, _copilot_reasoning = reasoning,
    reasoning_details = reasoning_details }
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
  assert(type(requests[#requests].on_text) == 'function')
  requests[#requests].on_text('Partial response')
  assert(#history.load(history.workspace(), id).messages == 2, 'previews must not enter saved history')
  assert(#executed == before and #callbacks == 1, 'previews must not execute tools')
  if limit == 1 then
    reply(batch('completed'))
    assert(#executed == before + 2, 'the allowed batch must execute')
    assert(#callbacks == 1, 'completed batch must request a follow-up')
    assert(vim.deep_equal(requests[#requests].messages[#requests[#requests].messages - 2].reasoning_details,
      reasoning_details), 'completed tool batches must retain chat-completions reasoning')
  end
  local before_limit = #executed
  reply(batch('blocked'))
  assert(#executed == before_limit, 'the over-limit batch must not execute')
  assert(#callbacks == 0 and pending, 'the limit must pause for the user')
  local saved = history.load(history.workspace(), id)
  assert_balanced(saved.messages)
  assert(#saved.messages == 2 + limit * 3, 'the pending batch must not be saved before a decision')
  local count = #requests
  plugin.send('Must wait for the decision')
  assert(#requests == count, 'the turn must remain busy while prompting')
  if limit == 0 then choose(nil) else choose('stop') end
  assert(#executed == before_limit, 'declined calls must not execute')
  local logged = {}
  for _, line in ipairs(vim.fn.readfile(vim.fn.stdpath('state') .. '/codeit/tool-errors.jsonl')) do
    local entry = vim.json.decode(line)
    if entry.tool_call_id then logged[entry.tool_call_id] = entry end
  end
  for i = 1, 2 do
    local entry = assert(logged['blocked' .. i], 'declined calls must be logged')
    assert(entry.raw_arguments == '{"path":"README.md"}' and entry.arguments.path == 'README.md')
    assert(entry.error:match('^Error: Tool call limit reached'))
  end
  assert(#callbacks == 1 and #requests[#requests].specs == 0,
    'declining must request one tool-free final response')
  local rejected = requests[#requests].messages
  assert(vim.deep_equal(rejected[#rejected - 2]._copilot_reasoning, reasoning),
    'declined tool batches must retain reasoning for the tool-free follow-up')
  assert(vim.deep_equal(rejected[#rejected - 2].reasoning_details, reasoning_details),
    'declined tool batches must retain chat-completions reasoning')
  assert_balanced(rejected)
  for i = #rejected - 1, #rejected do
    assert(rejected[i].role == 'tool' and rejected[i].content:find('Error: Tool call limit reached', 1, true))
  end
  reply({ role = 'assistant', content = 'Stopped because no more tools were allowed.' })
  saved = history.load(history.workspace(), id)
  assert_balanced(saved.messages)
  assert(#saved.messages == 6 + limit * 3, 'declined calls and final answer must be saved')
  assert(vim.deep_equal(saved.messages[#saved.messages - 3]._copilot_reasoning, reasoning),
    'encrypted reasoning must survive history save/load')
  assert(vim.deep_equal(saved.messages[#saved.messages - 3].reasoning_details, reasoning_details),
    'chat-completions reasoning must survive history save/load')
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

-- Default and custom extensions apply to this turn, and can be granted repeatedly.
plugin.setup({ max_tool_rounds = 1, max_context_tokens = false })
plugin.send('Continue with extra tools')
local before = #executed
reply(batch('first'))
reply(batch('default-extra'))
assert(#executed == before + 2 and pending)
local count = #requests
choose('continue')
assert(#executed == before + 4 and #requests == count + 1,
  'approval must execute the held batch without re-requesting it')
reply(batch('custom-extra'))
choose('custom')
for _, invalid in ipairs({ '0', '-1', '1.5', 'not a number', '1e309' }) do
  enter(invalid)
  assert(input and #executed == before + 4, 'invalid allowances must not execute tools')
end
enter('2')
assert(#executed == before + 6)
reply(batch('last-custom-round'))
assert(#executed == before + 8 and not pending, 'custom allowance must cover exactly two rounds')
reply(batch('blocked-again'))
assert(pending and #executed == before + 8, 'exhausting the extension must prompt again')
choose('stop')
reply({ role = 'assistant', content = 'Done.' })
plugin.send('Fresh turn has the original limit')
reply(batch('new-turn-allowed'))
reply(batch('new-turn-blocked'))
assert(pending, 'extensions must not change the configured limit for later turns')
choose('stop')
reply({ role = 'assistant', content = 'Done again.' })

-- Zero disables the default continuation choice but still allows a custom grant.
plugin.setup({ max_tool_rounds = 0, max_context_tokens = false })
plugin.send('Custom grant from zero')
reply(batch('zero'))
for _, option in ipairs(prompts[#prompts]) do assert(option.id ~= 'continue') end
choose('custom')
enter('1')
reply({ role = 'assistant', content = 'One round was enough.' })

-- Cancelling custom input declines safely; a provider cannot ignore disabled tools.
plugin.send('Cancel the custom allowance')
reply(batch('cancelled'))
choose('custom')
enter(nil)
local prompt_count, executed_count = #prompts, #executed
reply(batch('ignores-disabled-tools'))
assert(#callbacks == 0 and #prompts == prompt_count and #executed == executed_count,
  'a provider ignoring disabled tools must stop without a new prompt or execution')
assert_balanced(history.list(history.workspace())[1].messages)

-- Stale selection and input callbacks cannot resume a reset or another workspace.
for _, custom in ipairs({ false, true }) do
  plugin.new()
  plugin.send('Prompt then reset')
  reply(batch('stale'))
  if custom then choose('custom') end
  plugin.new()
  if custom then enter('4') else choose('continue') end
  assert(#callbacks == 0 and #executed == executed_count)
end
plugin.send('Prompt then change workspace')
reply(batch('workspace'))
local root, temporary = vim.fn.getcwd(), vim.fn.tempname()
vim.fn.mkdir(temporary, 'p')
vim.cmd.cd(temporary)
choose('custom')
assert(not input and #callbacks == 0 and #executed == executed_count)
vim.cmd.cd(root)
vim.fn.delete(temporary, 'rf')

-- Malformed calls fail before asking for an extension.
plugin.setup({ max_tool_rounds = 0, max_context_tokens = false })
plugin.send('Malformed batch')
prompt_count = #prompts
local malformed = batch('duplicate')
malformed.tool_calls[2].id = malformed.tool_calls[1].id
reply(malformed)
assert(#prompts == prompt_count and not pending and #callbacks == 0)

-- A normal assistant response at the boundary is allowed.
plugin.setup({ max_tool_rounds = 0, max_context_tokens = false })
plugin.send('No tools needed')
reply({ role = 'assistant', content = 'Finished without tools.' })
local saved = history.list(history.workspace())[1]
assert(saved.messages[#saved.messages].content == 'Finished without tools.')
assert(#prompts == prompt_count, 'a final answer at the limit must not prompt')
for _, invalid in ipairs({ -1, 0.5, '12', math.huge }) do
  local ok, err = pcall(plugin.setup, { max_tool_rounds = invalid })
  assert(not ok and tostring(err):find('nonnegative whole number', 1, true))
end
print('codeit tool limit tests passed')
