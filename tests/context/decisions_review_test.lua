vim.opt.runtimepath:prepend(vim.fn.getcwd())
local root, temp = vim.fn.getcwd(), vim.fn.tempname()
vim.fn.mkdir(temp, 'p')
vim.fn.chdir(temp)
local review = require('codeit.context.review')
local decisions = require('codeit.context.decisions')
local function call(id, name)
  return { id = id, type = 'function', ['function'] = { name = name, arguments = '{}' } }
end
local turn = {
  { role = 'user', content = 'Inspect and fix' },
  { role = 'assistant', content = 'Checking.', _copilot_reasoning = { encrypted = 'opaque' },
    _codex_reasoning = { encrypted = 'opaque' }, tool_calls = {
      call('long', 'read_file'), call('keep', 'run_command'), call('ask', 'ask_user'), call('skill', 'load_skill'),
    } },
  { role = 'tool', tool_call_id = 'long', content = string.rep('old data', 1000) },
  { role = 'tool', tool_call_id = 'keep', content = 'Unresolved test failure' },
  { role = 'tool', tool_call_id = 'ask', content = 'User clarification' },
  { role = 'tool', tool_call_id = 'skill', content = 'Skill instructions' },
  { role = 'assistant', content = 'Fixed the implementation, tests need follow-up.' },
}
local original = vim.deepcopy(turn)
local state, questions = decisions.prepare(turn)
assert(#state.exchanges == 2 and questions.remove_1.type == 'choice' and questions.remove_2.type == 'choice')
assert(state.exchanges[1].tool_call_id == 'long' and state.exchanges[1].bytes > state.exchanges[2].bytes)
assert(state.exchanges[1].estimated_tokens == math.ceil(state.exchanges[1].bytes / 4))
assert(questions.remove_1.instructions:find('future follow-up', 1, true))
local reordered = { turn[1], turn[2], turn[5], turn[3], turn[6], turn[4], turn[7] }
assert(#decisions.prepare(reordered).exchanges == 2, 'protected results must not hide later eligible exchanges')
local protected_only = { turn[1], { role = 'assistant', tool_calls = { call('ask', 'ask_user') } }, turn[5], turn[7] }
assert(#decisions.prepare(protected_only).exchanges == 0)
local unfinished = { turn[1], { role = 'assistant', tool_calls = { call('long', 'read_file') } } }
assert(#decisions.prepare(unfinished).exchanges == 0)
local function answers(first, second)
  return { remove_1 = { type = 'choice', choice = first or 'true' },
    remove_2 = { type = 'choice', choice = second or 'false' } }
end
local removals = assert(decisions.parse(answers(), state))
assert(#removals == 1 and removals[1].tool_call_id == 'long' and removals[1].remove == true and not removals[1].summary)
local projected = review.project(turn, { { first = 1, last = #turn, replacements = removals } })
assert(#projected == 6 and #projected[2].tool_calls == 3 and projected[2].tool_calls[1].id == 'keep')
assert(projected[2].content == 'Checking.' and not projected[2]._copilot_reasoning and not projected[2]._codex_reasoning)
assert(projected[3].tool_call_id == 'keep' and projected[4].tool_call_id == 'ask' and projected[5].tool_call_id == 'skill')
assert(vim.deep_equal(turn, original), 'review must not modify original history')
local mixed = review.project(turn, { { first = 1, last = #turn, replacements = {
  removals[1], { tool_call_id = 'keep', summary = 'Tests failed.' },
} } })
assert(mixed[2].content:find('Tests failed.', 1, true) and mixed[3].tool_calls[1].id == 'ask')
assert(#assert(decisions.parse(answers('false'), state)) == 0)
assert(not decisions.parse(nil, state))
assert(not decisions.parse({}, state))
assert(not decisions.parse(answers('maybe'), state))
assert(not decisions.parse(answers(true), state))
local invalid = answers()
invalid.remove_2.type = 'score'
assert(not decisions.parse(invalid, state), 'one malformed answer invalidates the whole review')
for _, id in ipairs({ 'ask', 'skill', 'unknown' }) do
  assert(not review.validate(turn, { { tool_call_id = id, remove = true } }))
end
assert(not review.validate(turn, { removals[1], removals[1] }))
assert(not review.validate(turn, { { tool_call_id = 'long', remove = true, summary = 'ambiguous' } }))
assert(not review.parse({ content = vim.json.encode({ replacements = removals }) }, turn),
  'chat-based reviewers must still provide factual summaries')
local single = { turn[1], { role = 'assistant', content = vim.NIL, tool_calls = { call('long', 'read_file') } }, turn[3], turn[7] }
local empty_batch, indices = review.project(single, { { first = 1, last = 4, replacements = removals } })
assert(#empty_batch == 2 and empty_batch[1].role == 'user' and empty_batch[2].content == turn[7].content)
assert(indices[1] == 1 and indices[2] == 4, 'compaction checkpoints must retain original indices')
local stored = { { role = 'system', content = 'system' } }
vim.list_extend(stored, turn)
assert(#review.restore(stored, { { first = 2, last = #stored, replacements = removals } }) == 1)

local requests, assessments = {}, {}
package.loaded['codeit.providers'] = {
  chat = function(config, messages, specs, callback)
    requests[#requests + 1] = { config = config, messages = vim.deepcopy(messages), specs = specs, callback = callback }
  end,
  decisions = function(config, data, qs, callback, active)
    assessments[#assessments + 1] = { config = config, state = data, questions = qs, callback = callback, active = active }
  end,
}
local tools = require('codeit.tools')
require('codeit.tools.approval').prefetch = function() return nil end
tools.execute = function(name, _, _, callback)
  callback(name == 'read_file' and string.rep('old data', 1000) or 'Unresolved test failure')
end
tools.request_specs = function() return { { type = 'function' } } end
local plugin = require('codeit')
local history = require('codeit.chat.storage')
plugin.setup({ system_prompt = 'system', max_context_tokens = false, context_review = 'decisions',
  feature_settings = { context_review = { provider = 'decisions', model = 'local',
    options = { base_url = 'http://localhost:8080/v1', api_key_env = '' } } } })
local function flush() vim.wait(30, function() return false end, 5) end
local function finish(question)
  local count = #assessments
  plugin.send(question)
  requests[#requests].callback({ content = 'Checking.', _codex_reasoning = { encrypted = 'opaque' }, tool_calls = {
    call('long', 'read_file'), call('keep', 'run_command'),
  } })
  requests[#requests].callback({ content = 'Fixed, tests still need follow-up.' })
  assert(vim.wait(1000, function() return #assessments == count + 1 end, 5))
  return assessments[#assessments]
end
local pending = finish('first')
assert(pending.config.provider == 'decisions' and pending.config.model == 'local')
assert(pending.state.turn[1].content == 'first' and not pending.state.turn[2]._codex_reasoning)
assert(pending.questions.remove_1 and pending.questions.remove_2)
local workspace = history.workspace()
local id = history.list(workspace)[1].id
plugin.send('second while review pending')
local second = requests[#requests]
assert(second.messages[3].tool_calls[1].id == 'long')
pending.callback(answers(), nil, { cost = 0.1, prompt_tokens = 100, completion_tokens = 2 })
local saved = history.load(workspace, id)
assert(#saved.context_reviews == 1 and saved.context_reviews[1].replacements[1].remove == true)
assert(saved.messages[4].content == string.rep('old data', 1000), 'raw transcript stays intact')
assert(saved.turn_costs[1].cost_by_function.context_review.cost == 0.1)
assert(not saved.turn_costs[2].cost_by_function.context_review, 'bill the originating turn')
second.callback({ content = 'Second done.' })
plugin.send('third')
local effective = requests[#requests].messages
assert(effective[3].tool_calls[1].id == 'keep' and effective[4].tool_call_id == 'keep')
assert(effective[3].content == 'Checking.' and effective[5].content == 'Fixed, tests still need follow-up.')
requests[#requests].callback({ content = 'Third done.' })
flush()
assert(#assessments == 1, 'plain prose must not trigger decisions requests')
plugin.resume(id)
plugin.send('after resume')
assert(requests[#requests].messages[3].tool_calls[1].id == 'keep')
requests[#requests].callback({ content = 'Resumed.' })
flush()
plugin.compact(true)
assert(not requests[#requests].messages[2].content:find(string.rep('old data', 50), 1, true))
requests[#requests].callback({ content = 'Compacted.' })
plugin.new()
pending = finish('invalid response')
pending.callback(answers('invalid'))
assert(#history.list(workspace)[1].context_reviews == 0)
plugin.new()
pending = finish('failed request')
pending.callback(nil, 'endpoint unavailable')
assert(#history.list(workspace)[1].context_reviews == 0)
plugin.new()
pending = finish('stale review')
plugin.new()
assert(not pending.active())
pending.callback(answers())
assert(#history.list(workspace)[1].context_reviews == 0)
pending = finish('disable while pending')
local values = plugin.get_settings()
assert(values.context_review == 'decisions')
values.context_review = false
assert(plugin.configure(values))
assert(not pending.active())
pending.callback(answers())
assert(#history.list(workspace)[1].context_reviews == 0, 'disabled reviews must not apply late removals')
local count = #assessments
plugin.send('disabled')
requests[#requests].callback({ content = '', tool_calls = { call('long', 'read_file') } })
requests[#requests].callback({ content = 'Done.' })
flush()
assert(#assessments == count)
assert(plugin.get_settings().context_review == false)
vim.fn.chdir(root)
vim.fn.delete(temp, 'rf')
print('decisions context review tests passed')
