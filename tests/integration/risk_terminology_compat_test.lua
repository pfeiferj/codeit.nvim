vim.opt.runtimepath:prepend(vim.fn.getcwd())
local risk = require('codeit.risk')
local settings = require('codeit.settings')
local tools = require('codeit.tools')
local approval = require('codeit.tools.approval')
local legacy = { approval = { tool_call_safety = true } }
assert(risk.settings(legacy).approval.tool_call_risk == true)
assert(legacy.approval.tool_call_safety == true and legacy.approval.tool_call_risk == nil)
assert(risk.approval({ tool_call_risk = false, tool_call_safety = true }).tool_call_risk == false)
assert(risk.assessment({ risk_score = 0, safety_score = 10 }).risk_score == 0)
assert(risk.assessment({ safety_score = 7 }).risk_score == 7)

package.loaded['codeit.providers'] = { chat = function(_, _, _, callback)
  callback({ role = 'assistant', content = 'Done.' })
end }
local plugin = require('codeit')
plugin.setup({ max_context_tokens = false, context_review = false, approval = { tool_call_safety = true } })
assert(plugin.get_settings().approval.tool_call_risk == true)
assert(plugin.get_settings().approval.tool_call_safety == nil)
assert(approval.uses_tool_call_risk())
for _, definition in ipairs(tools.request_specs(vim.fn.getcwd())) do
  local params = definition['function'].parameters
  assert(params.properties.risk_score and not params.properties.safety_score)
  assert(vim.tbl_contains(params.required, 'risk_score'))
end
local args = { argv = { 'inspect' }, summary = 'Inspect the project.', safety_score = 1, is_write = false }
assert(not tools.validate('run_command', args))
local process = require('codeit.process')
local runs = 0
process.run = function(_, _, callback)
  runs = runs + 1
  callback({ code = 0, stdout = 'inspected', stderr = '' })
end
tools.configure({ tool_call_safety = true, read_commands = { { argv = { 'inspect' } } }, validators = {
  function(_, executable)
    assert(executable.safety_score == nil and executable.risk_score == nil and executable.summary == nil)
  end,
} })
approval.prefetch('run_command', args, {})(function(summary, score, safe)
  assert(summary == 'Inspect the project.' and score == 1 and safe)
end)
local result
tools.execute('run_command', args, vim.api.nvim_get_current_buf(), function(value) result = value end)
assert(result and result:find('inspected', 1, true) and runs == 1)
assert(args.safety_score == 1 and args.risk_score == nil, 'legacy input must not be mutated')

local values = plugin.get_settings()
values.approval = { tool_call_safety = 'decisions' }
assert(settings.validate(values))
assert(settings.feature_config(values, 'tool_assessment').provider == 'typesafe')
assert(plugin.configure(values))
assert(approval.uses_decisions() and plugin.get_settings().approval.tool_call_risk == 'decisions')
values.approval = { tool_call_safety = false }
assert(plugin.configure(values))
assert(not approval.requires_summary())
plugin.setup({ max_context_tokens = false, context_review = false,
  approval = { tool_call_risk = false, tool_call_safety = true } })
assert(plugin.get_settings().approval.tool_call_risk == false, 'canonical false must override legacy true before defaults merge')
assert(not pcall(approval.setup, { tool_call_safety = 'invalid' }))

-- Read an old on-disk snapshot, then save its canonical form.
local workspace = vim.fn.tempname()
local path = vim.fn.stdpath('data') .. '/codeit/settings.json'
vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
values = plugin.get_settings()
values.approval = { tool_call_safety = true }
vim.fn.writefile({ vim.json.encode({ global = values, workspaces = {} }) }, path)
local restored = settings.resolve(plugin.get_settings(), workspace)
assert(restored.approval.tool_call_risk == true and restored.approval.tool_call_safety == nil)
assert(settings.save(restored, 'global', workspace))
local saved = vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
assert(saved.global.approval.tool_call_risk == true and saved.global.approval.tool_call_safety == nil)
values.approval = { tool_call_safety = false }
vim.fn.writefile({ vim.json.encode({ global = saved.global, workspaces = { [workspace] = values } }) }, path)
assert(settings.resolve(plugin.get_settings(), workspace).approval.tool_call_risk == false)
vim.fn.delete(path)

local audit = require('codeit.chat.auto_approvals')
local records = { { name = 'run_command', args = { argv = { 'inspect' } }, reason = 'read_only_command_rule', timestamp = 1,
  safety_score = 4, summary = 'Inspect the project.' } }
local restored_records = audit.restore(records)
assert(restored_records[1].risk_score == 4 and restored_records[1].safety_score == nil)
assert(records[1].safety_score == 4 and records[1].risk_score == nil)
local session = { workspace = 'workspace', chat_id = 'chat' }
audit.recorder(session, { save = function() end }, 'workspace', 'chat')('run_command', {}, 'test', { safety_score = 3 })
assert(session.auto_approvals[1].risk_score == 3 and session.auto_approvals[1].safety_score == nil)
local parsed = require('codeit.tools.approval.decisions').parse({
  safety_score = { type = 'score', score = 0 }, is_write = { type = 'choice', choice = 'false' },
}, false)
assert(parsed.risk_score == 1 and parsed.safety_score == nil)
tools.configure({ tool_call_risk = false, read_commands = { { argv = { 'inspect' } } } })
local subscribe = approval.prefetch('run_command', { argv = { 'inspect' } }, { review = function(_, callback)
  callback('{"summary":"Legacy reviewer response.","safety_score":1,"read_only":true,"rule_compliant":true}')
end })
assert(subscribe)
subscribe(function(summary, score, safe)
  assert(summary == 'Legacy reviewer response.' and score == 1 and safe)
end)
print('risk terminology compatibility tests passed')
