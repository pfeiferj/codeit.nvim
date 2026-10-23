vim.opt.runtimepath:prepend(vim.fn.getcwd())
local temp = vim.fn.tempname()
vim.fn.mkdir(temp, 'p')
vim.fn.chdir(temp)
vim.fn.writefile({ 'original' }, 'page.txt')
local requests, callbacks = {}, {}
package.loaded['codeit.providers'] = {
  chat = function(_, messages, specs, callback)
    requests[#requests + 1] = { messages = vim.deepcopy(messages), specs = specs }
    callbacks[#callbacks + 1] = callback
  end,
}
local tools = require('codeit.tools')
local agents = require('codeit.tools.subagents')
local pending, preview, question, commands = nil, nil, nil, 0
require('codeit.tools.approval.prompt').show = function(_, _, callback)
  assert(not pending, 'approvals must be serialized')
  pending = callback
end
require('codeit.tools.approval.write').show = function(diff, _, callback)
  assert(not pending)
  preview, pending = diff, callback
end
require('codeit.tools.question_prompt').show = function(_, _, callback) question = callback end
require('codeit.ui.input').show = function(options, callback) callback(options.expected) end
require('codeit.process').run = function(_, _, callback)
  commands = commands + 1
  callback({ code = 0, stdout = 'command completed', stderr = '' })
end
tools.configure({ tool_call_risk = 'disabled' })
local context = { subagent_config = { provider = 'openrouter', model = 'test', max_tool_rounds = 10 } }
local function wait_for(check) assert(vim.wait(1000, check, 5)) end
local function start()
  local count = #requests
  local result
  agents.start({ title = 'Approved work', task = 'Make a bounded change', mode = 'wait' }, nil, context,
    function(value) result = vim.json.decode(value) end)
  wait_for(function() return #requests == count + 1 end)
  return agents.list()[#agents.list()], function() return result end
end
local function call(name, args)
  args.summary = 'Perform the delegated ' .. name .. ' call.'
  return { id = name, ['function'] = { name = name, arguments = vim.json.encode(args) } }
end
local function reply(calls)
  table.remove(callbacks, 1)({ role = 'assistant', tool_calls = calls })
end
local function choose(value)
  wait_for(function() return pending ~= nil end)
  local callback = pending
  pending = nil
  callback(value)
end
local function next_request(count) wait_for(function() return #requests == count + 1 end) end
local run, result = start()
for _, definition in ipairs(requests[#requests].specs) do
  local fn = definition['function']
  assert(agents.allowed(fn.name))
  assert(fn.parameters.properties.summary, 'subagents need the same approval metadata as main chat')
end
local count = #requests
reply({ call('read_file', { path = 'page.txt' }) })
wait_for(function() return pending ~= nil end)
assert(#requests == count and #run.messages == 3, 'reading must wait for approval')
choose('once')
next_request(count)
assert(run.messages[#run.messages].content:find('original', 1, true))
count = #requests
reply({ call('edit_file', { path = 'page.txt', edits = { { old_text = 'original', new_text = 'changed' } } }) })
wait_for(function() return pending ~= nil end)
assert(preview.before == 'original\n' and preview.after == 'changed\n', 'read tracking must persist between rounds')
assert(vim.fn.readfile('page.txt')[1] == 'original' and #requests == count)
choose('once')
next_request(count)
assert(vim.fn.readfile('page.txt')[1] == 'changed')
count = #requests
reply({ call('create_file', { path = 'rejected.txt', content = 'must not exist' }) })
choose(nil)
next_request(count)
assert(vim.fn.filereadable('rejected.txt') == 0)
assert(run.messages[#run.messages].content:find('Rejected', 1, true))
count = #requests
reply({ call('run_command', { argv = { 'delegated-command' } }) })
wait_for(function() return pending ~= nil end)
assert(commands == 0 and #requests == count, 'commands must wait for approval')
choose('once')
next_request(count)
assert(commands == 1 and run.messages[#run.messages].content:find('command completed', 1, true))
count = #requests
reply({ call('ask_user', { question = 'Which option?' }),
  call('create_file', { path = 'deferred.txt', content = 'not yet' }) })
assert(question and #requests == count)
question('Use the first option')
next_request(count)
assert(run.messages[#run.messages - 1].content:find('Use the first option', 1, true))
assert(run.messages[#run.messages].content:find('Deferred:', 1, true))
assert(not pending and vim.fn.filereadable('deferred.txt') == 0)
table.remove(callbacks, 1)({ role = 'assistant', content = 'Completed approved work' })
assert(result().status == 'completed')

-- Scoped instructions invalidate calls planned before the subagent read them.
vim.fn.mkdir('src', 'p')
vim.fn.writefile({ 'Respect scoped restrictions.' }, 'src/AGENTS.md')
vim.fn.writefile({ 'before' }, 'src/scoped.txt')
tools.configure({ tool_call_risk = 'disabled', trusted_workspaces = { [temp] = 'all' } })
run, result = start()
count = #requests
reply({ call('read_file', { path = 'src/scoped.txt' }),
  call('edit_file', { path = 'src/scoped.txt', edits = { { old_text = 'before', new_text = 'after' } } }) })
next_request(count)
assert(not pending and vim.fn.readfile('src/scoped.txt')[1] == 'before')
assert(vim.json.encode(requests[#requests].messages):find('Respect scoped restrictions.', 1, true))
local deferred = false
for _, message in ipairs(run.messages) do
  if message.tool_call_id == 'edit_file' and message.content:find('Deferred:', 1, true) then deferred = true end
end
assert(deferred)
count = #requests
reply({ call('edit_file', { path = 'src/scoped.txt', edits = { { old_text = 'before', new_text = 'after' } } }) })
wait_for(function() return pending ~= nil end)
vim.fn.writefile({ 'Restrictions changed during approval.' }, 'src/AGENTS.md')
choose('once')
next_request(count)
assert(vim.fn.readfile('src/scoped.txt')[1] == 'before')
assert(vim.json.encode(requests[#requests].messages):find('Restrictions changed during approval.', 1, true))
assert(not vim.json.encode(requests[#requests].messages):find('Respect scoped restrictions.', 1, true),
  'old scoped system instructions must be replaced, not retained alongside their replacements')
table.remove(callbacks, 1)({ role = 'assistant', content = 'Reviewed updated instructions' })
assert(result().status == 'completed')

-- Skill activation and supporting resources belong to the subagent's own context.
vim.fn.mkdir('.agents/skills/review', 'p')
vim.fn.writefile({ '---', 'description: Review delegated changes', '---', 'SUBAGENT_SKILL_INSTRUCTIONS' },
  '.agents/skills/review/SKILL.md')
vim.fn.writefile({ 'Supporting reference.' }, '.agents/skills/review/reference.txt')
run, result = start()
count = #requests
reply({ call('load_skill', { name = 'review' }) })
next_request(count)
assert(vim.json.encode(requests[#requests].messages):find('SUBAGENT_SKILL_INSTRUCTIONS', 1, true))
count = #requests
reply({ call('read_skill_resource', { skill = 'review', path = 'reference.txt' }) })
next_request(count)
assert(run.messages[#run.messages].content:find('Supporting reference.', 1, true))
table.remove(callbacks, 1)({ role = 'assistant', content = 'Used the skill' })
assert(result().status == 'completed')

-- Approval assessments use independent callbacks and feature-specific billing.
tools.configure({})
local assessed
context.subagent_review_configs = { tool_assessment = { provider = 'openrouter', model = 'assessor' },
  tool_review = { provider = 'openrouter', model = 'reviewer' } }
context.subagent_feature_usage = function(usage, feature, provider)
  assessed = { usage = usage, feature = feature, provider = provider }
end
run, result = start()
count = #requests
local command = call('run_command', { argv = { 'reviewed-command' } })
local args = vim.json.decode(command['function'].arguments)
args.summary = nil
command['function'].arguments = vim.json.encode(args)
reply({ command })
next_request(count)
assert(#requests[#requests].specs == 0, 'risk assessment must not expose execution tools')
table.remove(callbacks, 1)({ role = 'assistant', content = '{"summary":"A bounded command","risk_score":1}' }, nil, { cost = 0.02 })
choose('once')
next_request(count + 1)
assert(commands == 2)
assert(assessed.feature == 'tool_assessment' and assessed.provider == 'openrouter' and assessed.usage.cost == 0.02)
table.remove(callbacks, 1)({ role = 'assistant', content = 'Approved after assessment' })
assert(result().status == 'completed')
context.subagent_review_configs, context.subagent_feature_usage = nil, nil
tools.configure({ tool_call_risk = 'disabled', trusted_workspaces = { [temp] = 'all' } })

-- User cancellation must stop the run, not invite the model to try again.
run, result = start()
reply({ call('create_file', { path = 'cancelled.txt', content = 'no' }),
  call('run_command', { argv = { 'must-not-run' } }) })
choose('cancel')
assert(result().status == 'cancelled' and commands == 2)
assert(vim.fn.filereadable('cancelled.txt') == 0)
run, result = start()
reply({ call('ask_user', { question = 'Cancel this?' }) })
question(nil)
assert(result().status == 'cancelled')

-- Cancelling a pending approval must make its eventual callback harmless.
run, result = start()
reply({ call('create_file', { path = 'late.txt', content = 'no' }) })
wait_for(function() return pending ~= nil end)
agents.cancel(run.id)
choose('once')
assert(result().status == 'cancelled' and vim.fn.filereadable('late.txt') == 0)

-- Workspace safety must also be checked after, not just before, approval.
run, result = start()
reply({ call('create_file', { path = 'wrong-workspace.txt', content = 'no' }) })
wait_for(function() return pending ~= nil end)
vim.fn.mkdir(temp .. '/other', 'p')
vim.fn.chdir(temp .. '/other')
choose('once')
assert(result().status == 'failed' and vim.fn.filereadable('wrong-workspace.txt') == 0)
vim.fn.chdir(temp)
assert(vim.fn.filereadable('wrong-workspace.txt') == 0)
agents.shutdown()
vim.fn.chdir(vim.fn.fnamemodify(temp, ':h'))
vim.fn.delete(temp, 'rf')
print('subagent approval tests passed')
