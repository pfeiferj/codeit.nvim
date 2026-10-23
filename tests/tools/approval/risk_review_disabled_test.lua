vim.opt.runtimepath:prepend(vim.fn.getcwd())
local root, dir = vim.fn.getcwd(), vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
vim.cmd.cd(dir)
local tools = require('codeit.tools')
local approval = require('codeit.tools.approval')
local prompt = require('codeit.tools.approval.prompt')
local input = require('codeit.ui.input')
local process = require('codeit.process')
local prompts, choose, result, runs = {}, nil, nil, 0
prompt.show = function(text, _, callback, config)
  assert(config.risk_score == 0 and not config.risk_unknown)
  prompts[#prompts + 1], choose = text, callback
end
input.show = function() error('disabled risk review must not require typed confirmation') end
process.run = function(_, _, callback)
  runs = runs + 1
  callback({ code = 0, stdout = 'inspected', stderr = '' })
end
local function unexpected() error('disabled risk review must not request an assessment') end
local context = { review = unexpected, decide = unexpected, assessment = unexpected }
local rule = { argv = { 'inspect' } }
local function configure(validators)
  tools.configure({ tool_call_risk = 'disabled', read_commands = { rule }, validators = validators })
end
local function execute(args, extra)
  prompts, choose, result = {}, nil, nil
  tools.execute('run_command', args, vim.api.nvim_get_current_buf(), function(value) result = value end,
    function() return true end, vim.tbl_extend('force', context, extra or {}))
  assert(vim.wait(2000, function() return result ~= nil or choose ~= nil end))
end
configure()
assert(approval.risk_review_disabled() and approval.requires_summary())
assert(not approval.uses_tool_call_risk() and not approval.uses_decisions())
for _, definition in ipairs(tools.request_specs(dir)) do
  local params = definition['function'].parameters
  assert(params.properties.summary and vim.tbl_contains(params.required, 'summary'))
  assert(params.properties.risk_score == nil and params.properties.is_write == nil)
end
for _, definition in ipairs(tools.specs) do
  assert(definition['function'].parameters.properties.summary == nil, 'base tool schemas remain unchanged')
end
assert(not tools.validate('run_command', { argv = { 'inspect' } }, { no_prompt = true }))
for _, args in ipairs({
  { argv = { 'inspect' } },
  { argv = { 'inspect' }, summary = '' },
  { argv = { 'inspect' }, summary = '  \n ' },
  { argv = { 'inspect' }, summary = false },
  { argv = { 'inspect' }, summary = string.rep('x', 161) },
  { argv = { 'inspect' }, summary = 'Inspect.', risk_score = 0 },
  { argv = { 'inspect' }, summary = 'Inspect.', is_write = false },
}) do
  execute(args)
  assert(result:find('Error:', 1, true) and #prompts == 0)
end
assert(runs == 0)
-- Neither a stale assessment nor supplied risk fields can override disabled defaults.
local subscription = approval.prefetch('run_command', {
  summary = '**Inspect**\n# heading', risk_score = 10, is_write = true,
}, context)
subscription(function(summary, score, safe)
  assert(summary == '\\*\\*Inspect\\*\\* \\# heading' and score == 0 and safe)
end)
execute({ argv = { 'inspect' }, summary = 'Inspect the project.' })
assert(result:find('inspected', 1, true) and #prompts == 0 and runs == 1)
-- Unmatched commands still require normal approval, but not risk confirmation.
execute({ argv = { 'other' }, summary = 'Inspect another way.' })
assert(result == nil and #prompts == 1)
assert(prompts[1]:find('Inspect another way.', 1, true))
assert(not prompts[1]:find('Risk score', 1, true) and not prompts[1]:find('Unavailable', 1, true))
choose('always')
assert(result:find('inspected', 1, true) and runs == 2)
execute({ argv = { 'other' }, summary = 'A different summary of the same call.' })
assert(result:find('inspected', 1, true) and #prompts == 0 and runs == 3)
configure({ function(name, args)
  assert(name == 'run_command' and vim.deep_equal(args, { argv = { 'inspect' } }))
  return 'reject', 'policy'
end })
execute({ argv = { 'inspect' }, summary = 'Inspect.' })
assert(result == 'Rejected by approval policy: policy' and runs == 3)
configure({ function() return 'ask' end })
execute({ argv = { 'inspect' }, summary = 'Inspect.' })
assert(result == nil and #prompts == 1, 'ask validators must still block auto-approval')
choose('once')
assert(result:find('inspected', 1, true) and runs == 4)
configure()
-- Typed file operands still need read permission before a rule can auto-approve.
vim.fn.writefile({ 'data' }, dir .. '/private.txt')
tools.configure({ tool_call_risk = 'disabled', read_commands = { { argv = { 'inspect', { file = 'read' } } } } })
execute({ argv = { 'inspect', 'private.txt' }, summary = 'Inspect a file.' })
assert(result == nil and #prompts == 1 and runs == 4)
choose(nil)
assert(result == 'Rejected by user')
assert(approval.set_workspace_trust('all', dir))
execute({ argv = { 'inspect', 'private.txt' }, summary = 'Inspect a file.' })
assert(result:find('inspected', 1, true) and #prompts == 0 and runs == 5)
-- Disabling risk review cannot bypass approval in a no-prompt context.
execute({ argv = { 'unmatched' } }, { no_prompt = true })
assert(result:find('requires approval', 1, true) and runs == 5)
vim.cmd.cd(root)
vim.fn.delete(dir, 'rf')
print('risk_review_disabled_test: ok')
