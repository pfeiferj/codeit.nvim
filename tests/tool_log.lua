vim.opt.runtimepath:prepend(vim.fn.getcwd())
local root = vim.fn.getcwd()
local log = require('codeit.tool_log')
local tools = require('codeit.tools')
local approval = require('codeit.approval')
local agent = require('codeit.agent_tools')
local path = vim.fn.stdpath('state') .. '/codeit/tool-errors.jsonl'
vim.fn.delete(path)
local workspace = vim.fn.tempname()
vim.fn.mkdir(workspace, 'p')
vim.cmd.cd(workspace)
local function entries()
  if vim.fn.filereadable(path) == 0 then return {} end
  return vim.tbl_map(vim.json.decode, vim.fn.readfile(path))
end
local result
local args = { path = 'missing.txt', buffer_id = 12 }
tools.execute('read_file', args, nil, function(value) result = value end)
local records = entries()
assert(#records == 1 and records[1].error == result and result:match('^Error:'))
assert(vim.deep_equal(records[1].arguments, args))
assert(records[1].tool == 'read_file')
assert(records[1].timestamp:match('^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d%.%d%d%d%d%d%dZ$'))
local head = vim.system({ 'git', '-C', root, 'rev-parse', 'HEAD' }, { text = true }):wait()
assert(records[1].integration_commit == vim.trim(head.stdout), 'must record integration HEAD outside workspace')
if vim.fn.has('unix') == 1 then
  assert(vim.fn.getfperm(path) == 'rw-------')
  assert(vim.fn.getfperm(vim.fn.fnamemodify(path, ':h')) == 'rwx------')
end

local system = vim.system
vim.system = function(argv)
  assert(argv[1] == 'git' and argv[3] == root)
  return { wait = function() return { code = 0, stdout = string.rep('a', 40) .. '\n' } end }
end
local entry = log.start('read_file', nil, '{broken JSON')
assert(entry.integration_commit == string.rep('a', 40))
vim.system = function() return { wait = function() return { code = 1 } end } end
assert(log.start('read_file', {}).integration_commit == vim.NIL)
vim.system = system
log.finish(entry, 'Error: arguments must be an object')
records = entries()
assert(#records == 2 and records[2].raw_arguments == '{broken JSON' and records[2].arguments == vim.NIL)
assert(records[2].integration_commit == string.rep('a', 40), 'commit must be captured at start, not completion')

approval.setup({ validators = { function() return 'approve' end } })
local execute = agent.execute
local pending
agent.execute = function(_, _, done) pending = done end
tools.execute('git_status', {}, nil, function(value) result = value end)
pending('Error: delayed failure')
pending('Error: duplicate failure')
assert(#entries() == 3 and result == 'Error: delayed failure')
tools.execute('git_status', {}, nil, function() error('stale callback') end, function() return false end)
assert(#entries() == 3)
tools.execute('git_status', {}, nil, function(value) result = value end)
pending('successful output\n[exit code: 0]')
assert(#entries() == 3)
agent.execute = function() error('unexpected exception') end
tools.execute('git_status', {}, nil, function(value) result = value end)
assert(#entries() == 4 and entries()[4].error == result and result:find('unexpected exception', 1, true))
agent.execute = execute
approval.setup({ validators = { function() return 'reject', 'policy reason' end } })
tools.execute('git_status', {}, nil, function(value) result = value end)
assert(#entries() == 5 and entries()[5].error == 'Rejected by approval policy: policy reason')

assert(log.failed('run_command', 'output\n[exit code: 1]'))
assert(log.failed('git_diff', '\n[exit code: -1]'))
assert(log.failed('search_workspace', '\n[exit code: 2]'))
assert(not log.failed('search_workspace', '\n[exit code: 1]'))
assert(log.failed('run_command', '\n[exit code: 0] [timed out]'))
assert(not log.failed('read_file', '{"lines":["Error: ordinary source text"]}'))
log.finish(entry, 'Cancelled by user', 'cancel')
assert(#entries() == 5)

-- An unwritable log cannot replace the result or prevent completion.
local fs_open, notify = vim.uv.fs_open, vim.notify
vim.uv.fs_open = function() return nil, 'simulated write failure' end
local warnings = 0
vim.notify = function(message) assert(message:find('simulated write failure', 1, true)); warnings = warnings + 1 end
tools.execute('read_file', {}, nil, function(value) result = value end)
assert(result == 'Error: missing argument path')
assert(vim.wait(1000, function() return warnings == 1 end))
tools.execute('read_file', {}, nil, function(value) result = value end)
vim.wait(20, function() return false end)
assert(warnings == 1 and result == 'Error: missing argument path')
vim.uv.fs_open, vim.notify = fs_open, notify
vim.cmd.cd(root)
vim.fn.delete(workspace, 'rf')
vim.fn.delete(path)
print('tool failure logging: ok')
