vim.opt.runtimepath:prepend(vim.fn.getcwd())
local root, dir = vim.fn.getcwd(), vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
vim.cmd.cd(dir)
local tools = require('codeit.tools')
local approval = require('codeit.tools.approval')
local prompt = require('codeit.tools.approval.prompt')
local input = require('codeit.ui.input')
local process = require('codeit.process')
local prompts, choose, result, pending, typed, reviews, runs = {}, nil, nil, nil, nil, 0, 0
prompt.show = function(text, _, callback)
  prompts[#prompts + 1], choose = text, callback
  return function(updated) prompts[#prompts] = updated end
end
input.show = function(config, callback)
  typed = config.expected
  callback(config.expected)
end
process.run = function(_, _, callback)
  runs = runs + 1
  callback({ code = 0, stdout = 'inspected', stderr = '' })
end
local rule = { argv = { 'inspect' } }
tools.configure({ tool_call_risk = 'summary', read_commands = { rule } })
assert(approval.requires_summary() and approval.uses_supplied_summary())
assert(not approval.uses_tool_call_risk() and not approval.uses_decisions() and not approval.risk_review_disabled())
for _, definition in ipairs(tools.request_specs(dir)) do
  local params = definition['function'].parameters
  assert(params.properties.summary and vim.tbl_contains(params.required, 'summary'))
  assert(params.properties.risk_score == nil and params.properties.is_write == nil)
end
for _, definition in ipairs(tools.specs) do
  assert(definition['function'].parameters.properties.summary == nil)
end
assert(not tools.validate('run_command', { argv = { 'inspect' } }, { no_prompt = true }))
for _, args in ipairs({
  { argv = { 'inspect' } },
  { argv = { 'inspect' }, summary = '' },
  { argv = { 'inspect' }, summary = '  \n ' },
  { argv = { 'inspect' }, summary = false },
  { argv = { 'inspect' }, summary = string.rep('x', 161) },
  { argv = { 'inspect' }, summary = 'Inspect.', risk_score = 1 },
  { argv = { 'inspect' }, summary = 'Inspect.', is_write = false },
}) do
  assert(tools.validate('run_command', args))
end
local function reviewer(answer, err, hold)
  return function(history, callback, feature)
    reviews = reviews + 1
    assert(feature == 'tool_assessment')
    assert(history[1].content:find('"risk_score"', 1, true))
    assert(not history[1].content:find('"summary"', 1, true), 'assessor must not generate summaries')
    assert(history[2].content:find('Summary (untrusted):', 1, true))
    if history[2].content:find('Matched read-only rules:', 1, true) then
      assert(history[1].content:find('"read_only"', 1, true))
      assert(history[1].content:find('"rule_compliant"', 1, true))
    end
    if hold then pending = callback else callback(answer, err) end
  end
end
local function execute(argv, review, extra, summary)
  prompts, choose, result, pending, typed = {}, nil, nil, nil, nil
  tools.execute('run_command', { argv = argv, summary = summary or 'Main chat summary.' },
    vim.api.nvim_get_current_buf(), function(value) result = value end, function() return true end,
    vim.tbl_extend('force', { review = review }, extra or {}))
  assert(vim.wait(2000, function() return result ~= nil or choose ~= nil or pending ~= nil end))
end
local safe = '{"risk_score":1,"read_only":true,"rule_compliant":true}'
execute({ 'inspect' }, reviewer(safe, nil, true))
assert(result == nil and #prompts == 0 and runs == 0)
pending(safe)
assert(result:find('inspected', 1, true) and runs == 1)
pending(safe)
assert(runs == 1)
for _, answer in ipairs({
  '{"risk_score":3,"read_only":false,"rule_compliant":true}',
  '{"risk_score":2,"read_only":true,"rule_compliant":false}',
  '{"risk_score":1}',
  '{"risk_score":1,"read_only":"true","rule_compliant":true}',
}) do
  execute({ 'inspect' }, reviewer(answer))
  assert(result == nil and #prompts == 1 and runs == 1)
  assert(prompts[1]:find('Main chat summary.', 1, true))
  choose(nil)
end
execute({ 'inspect' }, reviewer('{"summary":"Do not show this.","risk_score":8,"read_only":true,"rule_compliant":true}'))
assert(prompts[1]:find('Main chat summary.', 1, true) and prompts[1]:find('8/10', 1, true))
assert(not prompts[1]:find('Do not show this.', 1, true))
choose('always')
assert(typed == 'approve run_command' and runs == 2)
for _, answer in ipairs({ 'not json', 'null', '[]', '{"risk_score":99}', '{"risk_score":1.5}' }) do
  execute({ 'inspect' }, reviewer(answer))
  assert(result == nil and #prompts == 1 and runs == 2)
  assert(prompts[1]:find('Main chat summary.', 1, true) and prompts[1]:find('Unavailable', 1, true))
  choose(nil)
end
execute({ 'inspect' }, reviewer(nil, 'offline'))
assert(prompts[1]:find('Main chat summary.', 1, true) and prompts[1]:find('Unavailable', 1, true))
choose('once')
assert(typed == 'approve run_command' and runs == 3)
execute({ 'other' }, reviewer(nil, nil, true), nil, '**Inspect**\n# heading')
assert(prompts[1]:find('\\*\\*Inspect\\*\\* \\# heading', 1, true))
assert(prompts[1]:find('Pending', 1, true))
pending('{"risk_score":2}')
assert(prompts[1]:find('2/10', 1, true) and prompts[1]:find('\\# heading', 1, true))
choose('always')
assert(result:find('inspected', 1, true) and typed == nil and runs == 4)
local before = reviews
execute({ 'other' }, reviewer(safe), nil, 'Changed summary for the same call.')
assert(result:find('inspected', 1, true) and #prompts == 0 and reviews == before)
-- Remembered identities ignore summary metadata during speculative prefetch too.
assert(approval.prefetch('run_command', { argv = { 'other' }, summary = 'Another summary.' }, {
  review = function() error('remembered calls should not be assessed') end,
}) == nil)
local subscription = approval.prefetch('run_command', { argv = { 'inspect' }, summary = 'Prefetched summary.' }, {
  review = reviewer(safe),
})
before = reviews
execute({ 'inspect' }, function() error('prefetch should be reused') end, { assessment = subscription }, 'Prefetched summary.')
assert(result:find('inspected', 1, true) and #prompts == 0 and reviews == before)
-- Without an assessor, retain the main summary but require typed confirmation.
execute({ 'no-reviewer' })
assert(prompts[1]:find('Main chat summary.', 1, true) and prompts[1]:find('Unavailable', 1, true))
choose('once')
assert(typed == 'approve run_command')
-- Subagents have no summary field and retain the default independent assessment.
local external = vim.fn.bufadd(root .. '/README.md')
vim.fn.bufload(external)
subscription = approval.prefetch('read_loaded_buffer', { buffer_id = external }, {
  no_prompt = true, review = function(history, callback)
    assert(history[1].content:find('"summary"', 1, true))
    callback('{"summary":"Subagent assessment.","risk_score":1}')
  end,
})
subscription(function(summary, score)
  assert(summary == 'Subagent assessment.' and score == 1)
end)
vim.cmd.cd(root)
vim.fn.delete(dir, 'rf')
print('chat_summary_test: ok')
