vim.opt.runtimepath:prepend(vim.fn.getcwd())
local root = vim.fn.getcwd()
local temp = vim.fn.tempname()
vim.fn.mkdir(temp .. '/one', 'p')
vim.fn.mkdir(temp .. '/two', 'p')
vim.fn.chdir(temp .. '/one')
local review = require('codeit.context_review')
local function call(id, name, args)
  return { id = id, type = 'function', ['function'] = { name = name, arguments = vim.json.encode(args or {}) } }
end
local turn = {
  { role = 'user', content = 'Implement it' },
  { role = 'assistant', content = 'Inspect then edit.', _copilot_reasoning = { { encrypted_content = 'opaque' } },
    tool_calls = { call('long', 'edit_file', { path = 'main.lua', edits = { { old_text = string.rep('x', 1000), new_text = 'fixed' } } }),
      call('short', 'run_command', { argv = { 'test' } }), call('ask', 'ask_user'), call('skill', 'load_skill') } },
  { role = 'tool', tool_call_id = 'long', content = string.rep('output', 1000) },
  { role = 'tool', tool_call_id = 'short', content = 'Tests passed.' },
  { role = 'tool', tool_call_id = 'ask', content = '{"answer":"yes"}' },
  { role = 'tool', tool_call_id = 'skill', content = 'Instructions' },
  { role = 'assistant', content = 'Implemented; tests passed.' },
}
local replacement = { tool_call_id = 'long', summary = 'Updated main.lua to fix the implementation; saved on disk.' }
local function answer(replacements)
  return { role = 'assistant', content = vim.json.encode({ replacements = replacements or {} }) }
end
local decisions = assert(review.parse(answer({ replacement }), turn))
assert(#decisions == 1)
local projected = review.project(turn, { { first = 1, last = #turn, replacements = decisions } })
assert(#projected == #turn and projected[2].content:find('Updated main.lua', 1, true))
assert(projected[3].content == turn[2].content and #projected[3].tool_calls == 3)
assert(projected[3]._copilot_reasoning == nil and turn[2]._copilot_reasoning)
assert(projected[4].content == 'Tests passed.' and projected[5].tool_call_id == 'ask')
assert(not review.parse(answer({ { tool_call_id = 'missing', summary = 'Bad' } }), turn))
assert(not review.parse(answer({ replacement, replacement }), turn))
assert(not review.parse(answer({ { tool_call_id = 'ask', summary = 'Answer' } }), turn))
assert(not review.parse(answer({ { tool_call_id = 'skill', summary = 'Instructions' } }), turn))
assert(not review.parse({ content = 'not JSON' }, turn))
assert(not review.parse(answer({ { tool_call_id = 'long', summary = '' } }), turn))
assert(#assert(review.parse(answer({ { tool_call_id = 'short', summary = string.rep('w', 1000) } }), turn)) == 0)
assert(#assert(review.parse({ content = { { type = 'text', text = '```json\n' .. answer({ replacement }).content .. '\n```' } } }, turn)) == 1)
local all = review.project(turn, { { first = 1, last = #turn, replacements = {
  replacement, { tool_call_id = 'short', summary = 'Tests passed.' },
} } })
assert(#all[3].tool_calls == 2, 'retained calls must still have matching results')
local ephemeral = {
  { role = 'user', content = 'Inspect status' },
  { role = 'assistant', content = vim.NIL, tool_calls = { call('status', 'git_status') } },
  { role = 'tool', tool_call_id = 'status', content = string.rep('temporary status\n', 100) },
  { role = 'assistant', content = 'Inspected.' },
}
local ephemeral_decisions = assert(review.parse(answer({ { tool_call_id = 'status', summary = 'Checked Git status; no changes made.' } }), ephemeral))
local without_calls = review.project(ephemeral, { { first = 1, last = 4, replacements = ephemeral_decisions } })
assert(#without_calls == 3 and not without_calls[2].tool_calls and without_calls[3].content == 'Inspected.')
local incomplete = vim.deepcopy(ephemeral)
table.remove(incomplete, 3)
assert(not review.parse(answer({ { tool_call_id = 'status', summary = 'Checked.' } }), incomplete))
local stored = { { role = 'system', content = 'system' } }
vim.list_extend(stored, ephemeral)
assert(#review.restore(stored, { { first = 2, last = 5, replacements = ephemeral_decisions } }) == 1)
assert(#review.restore(stored, { { first = 2, last = 4, replacements = ephemeral_decisions } }) == 0)
assert(#review.restore(stored, { { first = 2, last = 5, replacements = { { tool_call_id = 'missing', summary = 'Bad.' } } } }) == 0)
-- Call IDs are scoped to turns, even when providers reuse them.
local repeated = vim.deepcopy(turn)
vim.list_extend(repeated, vim.deepcopy(turn))
local scoped = review.project(repeated, { { first = 1, last = #turn, replacements = decisions } })
assert(scoped[#turn + 2].tool_calls[1].id == 'long' and scoped[#turn + 3].tool_call_id == 'long')
assert(#review.restore({ { role = 'system', content = 'system' } }, { { first = 2, last = 99, replacements = decisions } }) == 0)

local history = require('codeit.history')
local requests, callbacks = {}, {}
package.loaded['codeit.providers'] = {
  chat = function(config, messages, specs, callback)
    requests[#requests + 1] = { config = vim.deepcopy(config), messages = vim.deepcopy(messages), specs = specs }
    callbacks[#callbacks + 1] = callback
  end,
}
local tools = require('codeit.tools')
require('codeit.approval').prefetch = function() return nil end
tools.execute = function(name, _, _, callback)
  callback(name == 'edit_file' and string.rep('edit result', 500) or 'Tests passed.')
end
tools.request_specs = function() return { { type = 'function' } } end
local plugin = require('codeit')
plugin.setup({ system_prompt = 'system', max_context_tokens = false,
  model_presets = { long_context = { model = 'review-model' } }, request_options = { openrouter = { effort = 'low' } } })
local workspace = history.workspace()
local function flush(expected)
  assert(vim.wait(1000, function() return #requests >= expected end, 10), 'background review was not scheduled')
  assert(#requests == expected)
end
local function finish_tool_turn(question)
  plugin.send(question)
  local main = #requests
  callbacks[main]({ role = 'assistant', content = 'Editing.', tool_calls = {
    call('long', 'edit_file', { path = 'main.lua' }), call('short', 'run_command', { argv = { 'test' } }),
  } })
  local continued = #requests
  assert(continued == main + 1)
  callbacks[continued]({ role = 'assistant', content = 'Done.' })
  flush(continued + 1)
  return continued + 1
end
local pending = finish_tool_turn('first')
local id = history.list(workspace)[1].id
assert(requests[pending].config.model == 'review-model' and requests[pending].config.options.effort == 'low')
assert(#requests[pending].specs == 0)
local reviewed = vim.json.decode(requests[pending].messages[2].content)
assert(reviewed[1].content == 'first' and reviewed[#reviewed].content == 'Done.')
assert(history.load(workspace, id).context_reviews and #history.load(workspace, id).context_reviews == 0)
plugin.send('second while review is pending')
local second = #requests
assert(#requests[second].specs > 0 and requests[second].messages[3].tool_calls[1].id == 'long',
  'pending review must not block the next turn or modify its snapshot')
callbacks[pending](answer({ replacement }), nil, { cost = 0.2, prompt_tokens = 20, completion_tokens = 10 })
local saved = history.load(workspace, id)
assert(#saved.context_reviews == 1 and saved.messages[4].content == string.rep('edit result', 500))
assert(saved.cost == 0.2 and saved.context_estimated == true)
assert(saved.turn_costs[1].cost == 0.2 and saved.turn_costs[1].missing_cost == 2)
assert(saved.cost_by_function.context_review.cost == 0.2 and saved.cost_by_function.context_review.requests == 1)
assert(saved.turn_costs[1].cost_by_function.context_review.cost == 0.2)
assert(saved.turn_costs[1].cost_by_function.main_chat.requests == 2)
assert(not saved.turn_costs[2].cost_by_function.context_review)
assert(saved.turn_costs[2].cost == 0 and saved.turn_costs[2].missing_cost == 0,
  'a late context review must bill its original turn, not the active turn')
plugin.send('must still be busy')
assert(#requests == second, 'review must not clear the active main-turn busy flag')
callbacks[second]({ role = 'assistant', content = 'Second done.' })
vim.wait(30, function() return false end, 10)
assert(#requests == second, 'plain prose turns must not incur a review request')
plugin.send('third')
local third = #requests
local effective = requests[third].messages
assert(effective[3].content:find('Updated main.lua', 1, true) and effective[4].tool_calls[1].id == 'short')
assert(effective[5].content == 'Tests passed.' and effective[6].content == 'Done.')
callbacks[third]({ role = 'assistant', content = 'Third done.' })
vim.wait(30, function() return false end, 10)
assert(#requests == third)
plugin.resume(id)
plugin.send('after resume')
assert(requests[#requests].messages[3].content:find('Updated main.lua', 1, true))
callbacks[#requests]({ role = 'assistant', content = 'Resumed done.' })
vim.wait(30, function() return false end, 10)
-- Failed/invalid reviews leave the effective context intact and chat usable.
plugin.new()
pending = finish_tool_turn('failure')
local failure_id = history.list(workspace)[1].id
callbacks[pending]({ content = 'invalid JSON' })
assert(#history.load(workspace, failure_id).context_reviews == 0)
plugin.send('continue after failure')
assert(requests[#requests].messages[3].tool_calls[1].id == 'long')
callbacks[#requests]({ content = 'ok' })
vim.wait(30, function() return false end, 10)
assert(#history.load(workspace, failure_id).context_reviews == 0)
-- Out-of-order reviews only update their own turns.
plugin.new()
local first_review = finish_tool_turn('one')
local second_review = finish_tool_turn('two')
local order_id = history.list(workspace)[1].id
callbacks[second_review](answer({ replacement }), nil, { cost = 0.3 })
callbacks[first_review](answer({ replacement }), nil, { cost = 0.1 })
saved = history.load(workspace, order_id)
assert(saved.turn_costs[1].cost == 0.1 and saved.turn_costs[2].cost == 0.3)
assert(#saved.context_reviews == 2 and saved.context_reviews[1].first == 2 and saved.context_reviews[2].first == 7)
plugin.resume(order_id)
plugin.send('both reviewed')
local notes = 0
for _, message in ipairs(requests[#requests].messages) do
  if type(message.content) == 'string' and message.content:find('Updated main.lua', 1, true) then notes = notes + 1 end
end
assert(notes == 2)
plugin.new()
-- Auto-compaction must count the pruned projection, not the huge raw output,
-- and must commit the original transcript checkpoint (6), not a projection index.
plugin.setup({ system_prompt = 'system', max_context_tokens = 1000 })
pending = finish_tool_turn('small reviewed turn' .. string.rep('q', 1200))
callbacks[pending](answer({ replacement }))
plugin.send(string.rep('u', 900))
local auto_main = #requests
assert(#requests[auto_main].specs > 0, 'pruned tool output must not spuriously trigger compaction')
callbacks[auto_main]({ content = string.rep('a', 700) })
vim.wait(30, function() return false end, 10)
local auto_id = history.list(workspace)[1].id
plugin.send('trigger compact')
local auto_summary = #requests
assert(#requests[auto_summary].specs == 0)
assert(requests[auto_summary].messages[2].content:find('Updated main.lua', 1, true))
callbacks[auto_summary]({ content = 'Auto summary.' })
assert(history.load(workspace, auto_id).compacted_until == 6)
local following = requests[#requests].messages
assert(following[3].content == string.rep('u', 900) and following[4].content == string.rep('a', 700))
plugin.setup({ system_prompt = 'system', max_context_tokens = false })
-- Compaction consumes reviewed context rather than resurrecting the raw output.
pending = finish_tool_turn('compact reviewed')
callbacks[pending](answer({ replacement }))
plugin.compact(true)
local compact = #requests
assert(requests[compact].messages[2].content:find('Updated main.lua', 1, true))
assert(not requests[compact].messages[2].content:find(string.rep('edit result', 50), 1, true))
callbacks[compact]({ content = 'Compacted.' })
assert(#history.list(workspace)[1].context_reviews == 0)
-- A pending review cannot undo a compaction that completed first.
plugin.new()
pending = finish_tool_turn('compact pending')
plugin.compact(true)
callbacks[#requests]({ content = 'Compacted pending.' })
callbacks[pending](answer({ replacement }))
assert(history.list(workspace)[1].context_summary == 'Compacted pending.' and #history.list(workspace)[1].context_reviews == 0)
-- Reset, workspace changes, and manual full-context edits reject stale reviews.
plugin.new()
pending = finish_tool_turn('reset')
plugin.new()
callbacks[pending](answer({ replacement }))
assert(#history.list(workspace)[1].context_reviews == 0)
pending = finish_tool_turn('workspace')
vim.fn.chdir(temp .. '/two')
callbacks[pending](answer({ replacement }))
assert(#history.list(workspace)[1].context_reviews == 0)
vim.fn.chdir(temp .. '/one')
plugin.new()
pending = finish_tool_turn('manual edit')
plugin.context_full()
local buf = vim.fn.bufnr('codeit://context-full')
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '[{"role":"system","content":"Manual system"},{"role":"user","content":"Manual context"}]' })
vim.cmd('write')
callbacks[pending](answer({ replacement }))
saved = history.list(workspace)[1]
assert(#saved.context_reviews == 0 and #saved.messages == 2 and saved.messages[2].content == 'Manual context')
vim.cmd('close')
-- The default is enabled, with an explicit opt-out independent of compaction.
plugin.setup({ context_review = false, max_context_tokens = false })
plugin.send('disabled')
local before = #requests
callbacks[before]({ content = 'No review.' })
vim.wait(30, function() return false end, 10)
assert(#requests == before)
assert(not pcall(plugin.setup, { context_review = 'yes' }))
vim.fn.chdir(root)
vim.fn.delete(temp, 'rf')
print('codeit background context review tests passed')
