vim.opt.runtimepath:prepend(vim.fn.getcwd())
local rules = require('codeit.tools.approval.command_rules')
local approval = require('codeit.tools.approval')
local prompt_ui = require('codeit.tools.approval.prompt')

local function matches(pattern, argv)
  return rules.match(rules.compile({ { argv = pattern } }), argv)
end
local function accepts(pattern, argv)
  return #matches(pattern, argv) > 0
end
assert(accepts({ 'man', '--', { string = true } }, { 'man', '--', 'git-rebase' }))
assert(accepts({ 'man', '--', { string = true } }, { 'man', '--', 'literal | $(text)' }))
assert(accepts({ 'tool', { string = true } }, { 'tool', '' }))
assert(not accepts({ 'man', '--', { string = true } }, { 'man', '--' }))
assert(not accepts({ 'man', '--', { string = true } }, { 'man', '--', 'printf', 'extra' }))
assert(not accepts({ 'man', '--', { string = true } }, { '/tmp/man', '--', 'printf' }))
assert(not accepts({ 'man', '--', { string = true } }, { 'sh', '-c', 'man printf' }))
local page = { 'man', '--', { string = { pattern = '[%w_.+-]+' } } }
assert(accepts(page, { 'man', '--', 'git-rebase' }))
assert(not accepts(page, { 'man', '--', '/tmp/git-rebase' }))
assert(not accepts(page, { 'man', '--', 'git-rebase/extra' }))
assert(accepts({ 'tool', { string = { pattern = '^abc$' } } }, { 'tool', 'abc' }))
assert(not accepts({ 'tool', { string = { pattern = 'abc' } } }, { 'tool', 'xabc' }))
assert(accepts({ 'tool', { string = { pattern = '%$' } } }, { 'tool', '$' }))
assert(not accepts({ 'tool', { string = { pattern = '%$' } } }, { 'tool', '$extra' }))
assert(accepts({ 'tool', { string = { pattern = '%%' } } }, { 'tool', '%' }))
local head = { 'head', '-n', { integer = { min = 1, max = 200 } }, '--', { file = 'read' } }
assert(accepts(head, { 'head', '-n', '200', '--', 'a.txt' }))
for _, value in ipairs({ '0', '201', '1.5', '1e2', ' 10', '0x10', 'nan' }) do
  assert(not accepts(head, { 'head', '-n', value, '--', 'a.txt' }), value)
end
local optional = { 'wc', { optional = { one_of = { '-l', '-w' } } }, '--', { file = 'read' } }
assert(accepts(optional, { 'wc', '--', 'a.txt' }))
assert(accepts(optional, { 'wc', '-w', '--', 'a.txt' }))
assert(not accepts(optional, { 'wc', '-c', '--', 'a.txt' }))
local repeated = { 'wc', '-l', '--', { repeat_arg = { file = 'read' }, min = 1, max = 2 } }
assert(vim.deep_equal(matches(repeated, { 'wc', '-l', '--', 'a', 'b' }), { { 'a', 'b' } }))
assert(not accepts(repeated, { 'wc', '-l', '--' }))
assert(not accepts(repeated, { 'wc', '-l', '--', 'a', 'b', 'c' }))
assert(not accepts(repeated, { 'wc', '-l', '--', '-' }))
assert(not accepts(repeated, { 'wc', '-l', '--', '' }))
assert(accepts({ 'tool', { repeat_arg = { string = true }, min = 0, max = 3 }, 'end' }, { 'tool', 'a', 'end' }))
assert(accepts({ 'tool', { repeat_arg = { string = true }, min = 0, max = 0 } }, { 'tool' }))
assert(accepts({ 'tool', { optional = { string = true } }, 'end' }, { 'tool', 'end' }))
local compiled = rules.compile({ { argv = { 'tool', { string = true } } } })
for _, argv in ipairs({ {}, { 'tool', 1 }, { 'tool', 'bad\0arg' }, { 'tool', string.rep('x', 4097) } }) do
  assert(#rules.match(compiled, argv) == 0)
end
assert(#rules.match(compiled, { [1] = 'tool', [3] = 'arg' }) == 0)
assert(#rules.match(compiled, vim.list_extend({ 'tool' }, vim.fn['repeat']({ 'x' }, 40))) == 0)
-- Lua's pattern parser can report an error only after matching a prefix.
assert(not accepts({ 'tool', { string = { pattern = 'a[' } } }, { 'tool', 'a' }))
assert(not accepts({ 'tool', { string = { pattern = 'a%b(' } } }, { 'tool', 'a(text$' }))
for _, config in ipairs({
  false, { argv = { 'tool' } }, { {} }, { { argv = {} } },
  { { argv = { { string = true } } } },
  { { argv = { 'tool', { string = true, file = 'read' } } } },
  { { argv = { 'tool', { file = 'write' } } } },
  { { argv = { 'tool', { string = false } } } },
  { { argv = { 'tool', { string = { pattern = '%' } } } } },
  { { argv = { 'tool', { string = { pattern = 'a%' } } } } },
  { { argv = { 'tool', { one_of = {} } } } },
  { { argv = { 'tool', { one_of = { 1 } } } } },
  { { argv = { 'tool', { integer = { min = 10, max = 1 } } } } },
  { { argv = { 'tool', { integer = { min = 1, max = math.huge } } } } },
  { { argv = { 'tool', { optional = 'x', extra = true } } } },
  { { argv = { 'tool', { optional = { optional = 'x' } } } } },
  { { argv = { 'tool', { repeat_arg = 'x', min = 1 } } } },
  { { argv = { 'tool', { repeat_arg = 'x', min = 0, max = 41 } } } },
  { { argv = { 'tool' }, unexpected = true } },
}) do
  local ok, err = pcall(rules.compile, config)
  assert(not ok and tostring(err):find('approval.read_commands', 1, true), vim.inspect(config))
end

assert(not pcall(approval.setup, { read_commands = false }))

local root, dir, other = vim.fn.getcwd(), vim.fn.tempname(), vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
vim.fn.mkdir(other, 'p')
vim.fn.writefile({ 'tracked' }, dir .. '/tracked.txt')
vim.fn.writefile({ 'untracked' }, dir .. '/untracked.txt')
vim.fn.writefile({ 'outside' }, other .. '/outside.txt')
assert(vim.fn.system({ 'git', '-C', dir, 'init', '-q' }) == '')
assert(vim.fn.system({ 'git', '-C', dir, 'add', 'tracked.txt' }) == '')
assert(vim.uv.fs_symlink(other .. '/outside.txt', dir .. '/escape.txt'))
assert(vim.uv.fs_symlink(dir .. '/tracked.txt', other .. '/trusted-link.txt'))
vim.cmd.cd(dir)
local configs = {
  { argv = head }, { argv = page }, { argv = repeated },
  { argv = { 'diff', '--', { file = 'read' }, { file = 'read' } } },
}
local function policy(mode, validators)
  approval.setup({ read_commands = configs, trusted_workspaces = mode and { [dir] = mode } or {}, validators = validators })
end
local prompted, last_prompt, result
local original_show = prompt_ui.show
prompt_ui.show = function(text, _, cb)
  prompted, last_prompt = true, text
  cb(nil)
end
local function safe_review(_, cb)
  cb('{"summary":"Reads information.","safety_score":1,"read_only":true,"rule_compliant":true}')
end
local function call(argv, expected_prompt, name, context)
  context = vim.tbl_extend('force', { review = safe_review }, context or {})
  prompted, result = false, nil
  approval.request(name or 'run_command', { argv = argv }, 'Run?', function() return true end,
    function(value) result = value end, function() result = 'executed' end, context)
  assert(prompted == expected_prompt, vim.inspect(argv) .. ': unexpected prompt: ' .. tostring(result))
  return result
end
policy(nil)
assert(call({ 'man', '--', 'printf' }, false) == 'executed')
assert(call({ 'man', '--', 'printf' }, false, nil, { no_prompt = true }) == 'executed')
assert(call({ 'unknown-command' }, false, nil, { no_prompt = true }):find('requires approval', 1, true))
call({ 'man', '--', '/tmp/page' }, true)
call({ 'man', '--', 'printf', '|', 'wc' }, true)
call({ 'head', '-n', '10', '--', 'tracked.txt' }, true)
assert(last_prompt:find('File argument requires read approval: tracked.txt', 1, true))
policy('tracked')
assert(call({ 'head', '-n', '10', '--', 'tracked.txt' }, false) == 'executed')
call({ 'head', '-n', '10', '--', 'untracked.txt' }, true)
call({ 'head', '-n', '10', '--', 'escape.txt' }, true)
call({ 'head', '-n', '10', '--', 'missing.txt' }, true)
call({ 'head', '-n', '10', '--', '.' }, true)
call({ 'head', '-n', '10', '--', 'tracked.txt', 'extra' }, true)
call({ 'diff', '--', 'tracked.txt', 'untracked.txt' }, true)
call({ 'wc', '-l', '--', 'tracked.txt', 'untracked.txt' }, true)
policy('all')
assert(call({ 'wc', '-l', '--', 'tracked.txt', 'untracked.txt' }, false) == 'executed')
assert(call({ 'diff', '--', 'tracked.txt', 'untracked.txt' }, false) == 'executed')
call({ 'head', '-n', '10', '--', other .. '/outside.txt' }, true)
call({ 'head', '-n', '10', '--', 'escape.txt' }, true)
call({ 'man', '--', 'printf' }, true, 'start_background_task')
-- File trust follows the destination, not the command's cwd.
vim.cmd.cd(other)
assert(call({ 'head', '-n', '10', '--', 'trusted-link.txt' }, false) == 'executed')
assert(call({ 'head', '-n', '10', '--', dir .. '/tracked.txt' }, false) == 'executed')
vim.cmd.cd(dir)
assert(approval.set_workspace_trust(nil))
call({ 'head', '-n', '10', '--', 'tracked.txt' }, true)
assert(approval.set_workspace_trust('all'))
policy('all', { function(name) if name == 'run_command' then return 'ask', 'Command review required' end end })
call({ 'man', '--', 'printf' }, true)
policy('all', { function(name) if name == 'run_command' then return 'reject', 'Blocked' end end })
assert(call({ 'man', '--', 'printf' }, false) == 'Rejected by approval policy: Blocked')
policy('all', { function(name) if name == 'read_file' then return 'ask', 'File review required' end end })
call({ 'head', '-n', '10', '--', 'tracked.txt' }, true)
assert(last_prompt:find('File review required', 1, true))
policy('all', { function(name) if name == 'read_file' then return 'reject', 'Private file' end end })
assert(call({ 'head', '-n', '10', '--', 'tracked.txt' }, false):find('Private file', 1, true))
policy('all', { function(name) if name == 'read_file' then error('broken file policy') end end })
assert(call({ 'head', '-n', '10', '--', 'tracked.txt' }, false):find('Validator error', 1, true))
policy('all', { function(name)
  if name == 'run_command' then return 'approve' end
  if name == 'read_file' then return 'ask' end
end })
call({ 'head', '-n', '10', '--', 'tracked.txt' }, true)
policy('all')
assert(approval.set_workspace_trust(nil))
local layout = require('codeit.ui.managed_tab')
local original_visible = layout.user_visible
layout.user_visible = function() return true end
call({ 'head', '-n', '10', '--', 'tracked.txt' }, true)
layout.user_visible = original_visible
policy(nil, { function(name) if name == 'read_file' then return 'approve' end end })
assert(call({ 'head', '-n', '10', '--', 'tracked.txt' }, false) == 'executed')
call({ 'head', '-n', '10', '--', 'missing.txt' }, true)
-- A broad overlapping rule cannot bypass an explicit file-policy decision.
approval.setup({ read_commands = {
  { argv = { 'wc', '--', { string = true } } },
  { argv = { 'wc', '--', { file = 'read' } } },
}, validators = { function(name) if name == 'read_file' then return 'reject', 'Private file' end end } })
assert(call({ 'wc', '--', 'tracked.txt' }, false):find('Private file', 1, true))
-- A previously allowed rule is removed by reconfiguration.
approval.setup({})
call({ 'man', '--', 'printf' }, true)
policy('all')
assert(approval.set_workspace_trust('all'))
-- Exercise the real dispatcher and process runner, not just approval.request.
local tools = require('codeit.tools')
result = nil
tools.execute('run_command', { argv = { 'wc', '-l', '--', 'tracked.txt' } }, nil,
  function(value) result = value end, function() return true end, { review = safe_review })
assert(vim.wait(5000, function() return result ~= nil end))
assert(result:find('tracked.txt', 1, true) and not result:find('Rejected', 1, true), result)
prompt_ui.show = original_show
assert(approval.set_workspace_trust(nil))
vim.cmd.cd(root)
vim.fn.delete(dir, 'rf')
vim.fn.delete(other, 'rf')
print('command_rules_test: ok')
