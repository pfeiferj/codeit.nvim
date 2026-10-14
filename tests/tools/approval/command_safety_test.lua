vim.opt.runtimepath:prepend(vim.fn.getcwd())
local approval = require('codeit.tools.approval')
local prompt_ui = require('codeit.tools.approval.prompt')
local definitions = require('codeit.settings.definitions')
assert(definitions.feature_presets.tool_assessment == 'fast')
local rule = { argv = { 'inspect', '--', { string = true } } }
local args = { argv = { 'inspect', '--', 'topic' } }
local safe = '{"summary":"Reads information.","safety_score":1,"read_only":true,"rule_compliant":true}'
local write = '{"summary":"Writes a file.","safety_score":3,"read_only":false,"rule_compliant":true}'
local escape = '{"summary":"Reads beyond the allowed scope.","safety_score":2,"read_only":true,"rule_compliant":false}'
local risky = '{"summary":"Risky invocation.","safety_score":7,"read_only":true,"rule_compliant":true}'
local original_show, original_input = prompt_ui.show, require('codeit.ui.input').show
local prompts, choose, result, actions, reviews, pending, live, typed = {}, nil, nil, 0, 0, nil, true, nil
prompt_ui.show = function(text, _, cb)
  prompts[#prompts + 1] = text
  choose = cb
end
require('codeit.ui.input').show = function(config, cb)
  typed = config.prompt
  cb('approve run_command')
end
local function configure(validators)
  approval.setup({ read_commands = { rule }, validators = validators })
end
local function reviewer(answer, err, hold)
  return function(history, cb, feature, active)
    reviews = reviews + 1
    assert(feature == 'tool_assessment', 'must use the fast-preset assessment feature')
    assert(#history == 2 and history[1].role == 'system' and history[2].role == 'user')
    assert(history[1].content:find('read_only', 1, true))
    assert(history[1].content:find('rule_compliant', 1, true))
    assert(history[1].content:find('no implicit shell', 1, true))
    assert(history[2].content:find('Matched read-only rules:', 1, true))
    assert(history[2].content:find('"string":true', 1, true))
    assert(history[2].content:find('Workspace:', 1, true))
    assert(not active or active())
    if hold then pending = cb else cb(answer, err) end
  end
end
local function request(context, argv)
  result, choose, typed, pending, prompts, live = nil, nil, nil, nil, {}, true
  approval.request('run_command', argv and { argv = argv } or args, 'Run?', function() return live end,
    function(value) result = value end, function() actions = actions + 1; result = 'executed' end, context)
end
configure()
request({ review = reviewer(safe) })
assert(result == 'executed' and #prompts == 0 and reviews == 1)
request({ review = reviewer(nil, nil, true) })
assert(result == nil and actions == 1 and #prompts == 0, 'must wait for model before executing')
pending(safe)
assert(result == 'executed' and actions == 2 and #prompts == 0)
pending(safe)
assert(actions == 2, 'duplicate provider callbacks must not execute twice')
request({ review = reviewer(write) })
assert(result == nil and #prompts == 1)
assert(prompts[1]:find('Automatic command approval blocked', 1, true))
assert(prompts[1]:find('Writes a file.', 1, true))
assert(prompts[1]:find('3/10', 1, true))
choose('once')
assert(result == 'executed' and typed == nil, 'model veto falls back to standard manual approval')
request({ review = reviewer(escape) })
assert(result == nil and #prompts == 1)
choose(nil)
assert(result == 'Rejected by user')
request({ review = reviewer(risky) })
assert(result == nil and #prompts == 1)
choose('once')
assert(result == 'executed' and typed:find('approve run_command', 1, true))
for _, answer in ipairs({
  'not json',
  '{"summary":"Reads.","safety_score":1}',
  '{"summary":"Reads.","safety_score":1,"read_only":"true","rule_compliant":true}',
  '{"summary":"Reads.","safety_score":1,"read_only":true,"rule_compliant":1}',
  '{"summary":"Reads.","safety_score":1,"read_only":true}',
  '{"summary":"Reads.","safety_score":99,"read_only":true,"rule_compliant":true}',
}) do
  request({ review = reviewer(answer) })
  assert(result == nil and #prompts == 1, answer)
  choose(nil)
  assert(result == 'Rejected by user')
end
request({ review = reviewer(nil, 'offline') })
assert(result == nil and #prompts == 1)
assert(prompts[1]:find('reviewer error', 1, true))
choose(nil)
request({ review = function() error('provider failed') end })
assert(result == nil and #prompts == 1)
assert(prompts[1]:find('reviewer error', 1, true))
choose(nil)
request({})
assert(result == nil and #prompts == 1)
assert(prompts[1]:find('reviewer not configured', 1, true))
choose('once')
assert(result == 'executed' and typed:find('approve run_command', 1, true))
request({ review = reviewer(write), no_prompt = true })
assert(result:find('requires approval', 1, true) and #prompts == 0)
request({ review = reviewer(safe), no_prompt = true })
assert(result == 'executed' and #prompts == 0)
-- Completed prefetches are reused for both the gate and the manual preview.
local before = reviews
local subscription = approval.prefetch('run_command', args, { review = reviewer(write) }, function() return true end)
request({ assessment = subscription, review = function() error('must not assess twice') end })
assert(#prompts == 1 and reviews == before + 1 and result == nil)
choose('always')
assert(result == 'executed')
-- Remembering this matching invocation does not bypass its next model check.
request({ review = reviewer(write) })
assert(result == nil and #prompts == 1)
choose(nil)
configure({ function(name) if name == 'run_command' then return 'approve' end end })
request({ review = reviewer(escape) })
assert(result == nil and #prompts == 1, 'command approval validator must not bypass a matching rule safety gate')
choose(nil)
-- Commands approved explicitly without a rule retain the existing policy.
before = reviews
request({ review = reviewer(nil, nil, true) }, { 'other-command' })
assert(result == 'executed' and reviews == before)
configure()
request({ review = reviewer(nil, nil, true) })
local cancelled = pending
before = actions
live = false
cancelled(safe)
assert(actions == before and result == nil and #prompts == 0)
request({ review = reviewer(nil, nil, true) })
local outdated = pending
configure()
outdated(safe)
assert(result == nil and #prompts == 1, 'changed rule configuration requires manual approval')
choose(nil)
-- A prefetch made under old rules must not authorize a new rule definition.
subscription = approval.prefetch('run_command', args, { review = reviewer(safe) }, function() return true end)
configure()
request({ assessment = subscription })
assert(result == nil and #prompts == 1)
choose(nil)

local cwd, dir = vim.fn.getcwd(), vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
vim.fn.writefile({ 'data' }, dir .. '/data.txt')
vim.cmd.cd(dir)
approval.setup({ read_commands = { { argv = { 'inspect', '--', { file = 'read' } } } },
  trusted_workspaces = { [dir] = 'all' } })
request({ review = function(_, cb) pending = cb end }, { 'inspect', '--', 'data.txt' })
assert(result == nil and #prompts == 0)
assert(approval.set_workspace_trust(nil))
pending(safe)
assert(result == nil and #prompts == 1, 'trust revoked during review must block auto-approval')
assert(prompts[1]:find('File argument requires read approval', 1, true))
choose(nil)
vim.cmd.cd(cwd)
vim.fn.delete(dir, 'rf')
prompt_ui.show, require('codeit.ui.input').show = original_show, original_input
print('command_safety_test: ok')
