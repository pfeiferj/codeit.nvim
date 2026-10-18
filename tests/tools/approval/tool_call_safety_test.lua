vim.opt.runtimepath:prepend(vim.fn.getcwd())
local root, dir = vim.fn.getcwd(), vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
vim.cmd.cd(dir)
local tools = require('codeit.tools')
local approval = require('codeit.tools.approval')
local prompt = require('codeit.tools.approval.prompt')
local input = require('codeit.ui.input')
local process = require('codeit.process')
local fields = { 'summary', 'safety_score', 'is_write' }
local rule = { argv = { 'inspect', '--', { string = true } } }
local prompts, choose, result, typed, actions, reviews = {}, nil, nil, nil, 0, 0
local original_show, original_input, original_run = prompt.show, input.show, process.run
prompt.show = function(text, _, callback)
  prompts[#prompts + 1], choose = text, callback
end
input.show = function(config, callback)
  typed = config.expected
  callback('approve run_command')
end
process.run = function(argv, _, callback)
  assert(vim.deep_equal(argv, { 'inspect', '--', 'topic' }))
  actions = actions + 1
  callback({ code = 0, stdout = 'inspected', stderr = '' })
end
local function reviewer(_, callback)
  reviews = reviews + 1
  callback('{"summary":"Independent assessment.","safety_score":1,"read_only":true,"rule_compliant":true}')
end
local function configure(enabled, validators)
  tools.configure({ tool_call_safety = enabled, read_commands = { rule }, validators = validators })
end
local function args(overrides)
  return vim.tbl_extend('force', { argv = { 'inspect', '--', 'topic' },
    summary = 'Reads information.', safety_score = 1, is_write = false }, overrides or {})
end
local function execute(arguments, context)
  prompts, choose, result, typed = {}, nil, nil, nil
  tools.execute('run_command', arguments, vim.api.nvim_get_current_buf(), function(value) result = value end,
    function() return true end, context or { review = reviewer })
  assert(vim.wait(2000, function() return result ~= nil or choose ~= nil end))
end

assert(require('codeit.settings.defaults').approval.tool_call_safety == false)
configure(false)
for _, definition in ipairs(tools.request_specs(dir)) do
  for _, key in ipairs(fields) do assert(definition['function'].parameters.properties[key] == nil) end
end
assert(tools.validate('run_command', args()):find('unknown argument', 1, true))
for _, bad in ipairs({ 'true', 1, {}, vim.NIL }) do
  assert(not pcall(approval.setup, { tool_call_safety = bad }))
end
configure(true)
for _, definition in ipairs(tools.request_specs(dir)) do
  local parameters = definition['function'].parameters
  for _, key in ipairs(fields) do
    assert(parameters.properties[key] and vim.tbl_contains(parameters.required, key))
  end
  assert(parameters.properties.safety_score.minimum == 0 and parameters.properties.safety_score.maximum == 10)
  assert(parameters.additionalProperties == false)
end
-- Shared definitions remain unchanged for subagents and subsequent disabled requests.
for _, definition in ipairs(tools.specs) do
  for _, key in ipairs(fields) do assert(definition['function'].parameters.properties[key] == nil) end
end
assert(not tools.validate('run_command', args()))
for _, key in ipairs(fields) do
  local missing = args()
  missing[key] = nil
  assert(tools.validate('run_command', missing) == 'missing argument ' .. key)
  execute(missing)
  assert(result:find('missing argument ' .. key, 1, true) and #prompts == 0)
end
for _, invalid in ipairs({
  { safety_score = -1 }, { safety_score = 11 }, { safety_score = 1.5 }, { safety_score = '1' },
  { summary = '' }, { summary = '  \n ' }, { summary = string.rep('x', 161) },
  { summary = false }, { is_write = 'false' }, { is_write = vim.NIL },
}) do
  execute(args(invalid))
  assert(result:find('Error:', 1, true) and #prompts == 0)
end
assert(actions == 0 and reviews == 0)
assert(not tools.validate('list_windows', {}, { no_prompt = true }))
assert(tools.validate('list_windows', {}) == 'missing argument summary')

local subscription = approval.prefetch('run_command', args(), { review = reviewer })
subscription(function(summary, score, safe)
  assert(summary == 'Reads information.' and score == 1 and safe)
end)
assert(reviews == 0)
execute(args())
assert(result:find('inspected', 1, true) and #prompts == 0 and actions == 1 and reviews == 0)
-- The write flag blocks rule auto-approval even with a low score.
execute(args({ is_write = true, safety_score = 3, summary = 'Writes a file.' }))
assert(result == nil and #prompts == 1 and prompts[1]:find('Writes a file.', 1, true))
assert(prompts[1]:find('3/10', 1, true))
choose('once')
assert(result:find('inspected', 1, true) and not typed and actions == 2)
execute(args({ safety_score = 7 }))
assert(result == nil and prompts[1]:find('7/10', 1, true))
choose('always')
assert(result:find('inspected', 1, true) and typed == 'approve run_command')
-- Non-matching commands also use supplied values without an automatic review.
execute(args({ argv = { 'unmatched' }, summary = '**Danger**\n# heading', safety_score = 9 }))
assert(result == nil and #prompts == 1 and prompts[1]:find('9/10', 1, true))
assert(prompts[1]:find('\\*\\*Danger\\*\\* \\# heading', 1, true))
choose(nil)
assert(result == 'Rejected by user' and reviews == 0)
-- Validators see only executable arguments; explicit rejection still wins.
configure(true, { function(name, arguments)
  assert(name == 'run_command' and vim.deep_equal(arguments, { argv = { 'inspect', '--', 'topic' } }))
  return 'reject', 'policy'
end })
execute(args())
assert(result:find('Rejected by approval policy', 1, true) and #prompts == 0)
configure(true)
-- A stale secondary assessment cannot override the supplied write flag.
execute(args({ is_write = true }), { review = reviewer, assessment = function(callback)
  error('secondary assessment must not be used')
end })
assert(result == nil and #prompts == 1)
choose(nil)
-- Malformed supplied metadata fails closed even at the approval layer, without a reviewer.
prompts, choose, result = {}, nil, nil
approval.request('run_command', { argv = { 'inspect', '--', 'topic' } }, 'Run?', nil,
  function(value) result = value end, function() error('must not auto-approve') end, { review = reviewer })
assert(vim.wait(2000, function() return choose ~= nil end))
assert(prompts[1]:find('Unavailable', 1, true))
choose(nil)
assert(result == 'Rejected by user' and reviews == 0)

configure(false)
for _, definition in ipairs(tools.request_specs(dir)) do
  for _, key in ipairs(fields) do assert(definition['function'].parameters.properties[key] == nil) end
end
execute({ argv = { 'inspect', '--', 'topic' } })
assert(result:find('inspected', 1, true) and reviews == 1, 'disabled mode retains independent assessment')
prompt.show, input.show, process.run = original_show, original_input, original_run
vim.cmd.cd(root)
vim.fn.delete(dir, 'rf')
print('tool_call_safety_test: ok')
