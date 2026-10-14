vim.opt.runtimepath:prepend(vim.fn.getcwd())
local temp = vim.fn.tempname()
vim.fn.mkdir(temp, 'p')
local stdpath = vim.fn.stdpath
vim.fn.stdpath = function(kind) return kind == 'data' and temp or stdpath(kind) end
local history = require('codeit.chat.storage')
local audit = require('codeit.chat.auto_approvals')
local approval = require('codeit.tools.approval')
local prompt = require('codeit.tools.approval.prompt')
local choice = 'once'
prompt.show = function(_, _, callback) callback(choice) end
vim.ui.input = function(_, callback) callback(nil) end
local workspace = history.workspace()
local session = { workspace = workspace, chat_id = 'audit', auto_approvals = {} }
local saves = 0
local function save()
  saves = saves + 1
  assert(history.save(session.workspace, session.chat_id, { provider = 'openrouter', model = 'test',
    messages = {}, auto_approvals = session.auto_approvals }))
end
local record = audit.recorder(session, { save = save }, workspace, 'audit')
local result, actions = nil, 0
local function request(name, args, context, active)
  result = nil
  context = vim.tbl_extend('force', { on_auto_approval = record, tool_call_id = 'call-1' }, context or {})
  approval.request(name, args, 'test', active or function() return true end,
    function(value) result = value end, function() actions = actions + 1; result = 'executed' end, context)
end
approval.setup({ validators = {} })
request('read_file', { path = 'not-trusted' })
assert(result == 'executed' and #session.auto_approvals == 0, 'manual approvals are not automatic')
choice = 'reject'
request('read_file', { path = 'not-trusted' })
assert(result == 'Rejected by user' and #session.auto_approvals == 0)
approval.setup({ validators = { function() return 'approve' end } })
local args = { path = 'example' }
request('read_file', args)
args.path = 'mutated'
assert(#session.auto_approvals == 1 and session.auto_approvals[1].reason == 'validator')
assert(session.auto_approvals[1].args.path == 'example' and session.auto_approvals[1].tool_call_id == 'call-1')
request('read_file', args, nil, function() return false end)
assert(#session.auto_approvals == 1, 'inactive calls must not be recorded or executed')
approval.setup({ validators = { function() return 'reject' end } })
request('read_file', args)
assert(result:find('Rejected by approval policy', 1, true) and #session.auto_approvals == 1)
approval.setup({ validators = {} })
assert(approval.set_workspace_trust('all', workspace))
request('list_workspace_files', {})
assert(session.auto_approvals[2].reason == 'trusted_read_or_window')
assert(approval.set_workspace_trust(nil, workspace))
choice = 'always'
request('read_file', { path = 'remember-this' })
assert(#session.auto_approvals == 2, 'the first remembered approval is still manual')
request('read_file', { path = 'remember-this' })
assert(session.auto_approvals[3].reason == 'remembered_exact_call')
local answer = '{"summary":"Reads information.","safety_score":1,"read_only":true,"rule_compliant":true}'
approval.setup({ read_commands = { { argv = { 'inspect', { string = true } } } } })
request('run_command', { argv = { 'inspect', 'a' } }, { review = function(_, cb) cb(answer) end })
assert(#session.auto_approvals == 4 and session.auto_approvals[4].reason == 'read_only_command_rule')
assert(session.auto_approvals[4].safety_score == 1 and session.auto_approvals[4].summary == 'Reads information.')
choice = 'reject'
request('run_command', { argv = { 'inspect', 'b' } }, { review = function(_, cb) cb('invalid') end })
assert(#session.auto_approvals == 4, 'failed command assessment is not auto-approved')
-- A delayed subagent record stays with its originating saved chat.
session.chat_id, session.auto_approvals = 'different', {}
record('read_file', { path = 'background' }, 'validator', { subagent_run_id = 7 })
assert(#session.auto_approvals == 0)
local saved = assert(history.load(workspace, 'audit'))
assert(#saved.auto_approvals == 5 and saved.auto_approvals[5].subagent_run_id == 7)
assert(history.delete(workspace, 'audit'))
record('read_file', {}, 'validator')
assert(history.load(workspace, 'audit') == nil, 'never resurrect deleted chats')
assert(#audit.restore(vim.NIL) == 0 and #audit.restore({ { name = 'bad' } }) == 0)

local tools_module = require('codeit.tools.auto_approvals')
local chats = { { workspace = workspace, id = 'one', auto_approvals = saved.auto_approvals,
  messages = { { role = 'user', content = 'Investigate this project' },
    { role = 'assistant', content = 'Done', reasoning_details = { { text = 'private-secret' } } } } },
  { workspace = workspace, id = 'old', messages = {} },
  { workspace = '/other', id = 'two', messages = {}, auto_approvals = {
    { name = 'run_command', args = { argv = { '/usr/bin/inspect', '--other' } }, reason = 'validator', timestamp = 1 },
    { name = 'run_command', args = { argv = { 'inspect', '--more' } }, reason = 'validator', timestamp = 2 },
  } } }
local tools = tools_module.new(chats)
local function execute(name, args) return vim.json.decode(tools.execute(name, args or {})) end
local stats = execute('get_auto_approval_stats')
assert(stats.total_approvals == 7 and #stats.entries == 4)
local commands = {}
for _, group in ipairs(stats.entries) do if group.command then commands[group.command] = group.count end end
assert(commands.inspect == 2 and commands['/usr/bin/inspect'] == 1, 'group by exact argv[1], not basename or subcommand')
local calls = execute('list_auto_approvals', { name = 'run_command', command = 'inspect' })
assert(#calls.entries == 2)
local detail = execute('read_auto_approval', { id = calls.entries[1].id })
assert(table.concat(detail.lines, '\n'):find('safety_score = 1', 1, true))
local context = execute('read_auto_approval_chat', { id = calls.entries[1].id })
assert(table.concat(context.lines, '\n'):find('Investigate this project', 1, true))
assert(not table.concat(context.lines, '\n'):find('private-secret', 1, true))
for _, bad in ipairs({ { offset = -1 }, { offset = math.huge }, { extra = true } }) do
  assert(tools.execute('get_auto_approval_stats', bad):match('^Error:'))
end
assert(tools.execute('run_command', {}):match('^Error:'))
assert(tools.execute('read_auto_approval', { id = 999 }):match('^Error:'))
assert(tools.execute('read_auto_approval', { id = 1, start_line = 5, end_line = 2 }):match('^Error:'))
local many = { { workspace = workspace, id = 'many', messages = {}, auto_approvals = {} } }
for i = 1, 120 do
  many[1].auto_approvals[i] = { name = 'tool-' .. i, args = { text = string.rep('λ', 2000) },
    reason = 'validator', timestamp = i }
end
tools = tools_module.new(many)
local first = execute('list_auto_approvals')
assert(first.truncated and first.next_offset == #first.entries)
assert(#tools.execute('list_auto_approvals', {}) < 20000)
local second = execute('list_auto_approvals', { offset = first.next_offset })
assert(second.entries[1].id ~= first.entries[#first.entries].id)
assert(execute('get_auto_approval_stats').truncated)
-- Very long arguments remain readable with bounded line pagination.
many[1].auto_approvals[1].args.text = string.rep('λ', 30000)
tools = tools_module.new(many)
local long = execute('list_auto_approvals', { name = 'tool-1' }).entries[1]
local page = execute('read_auto_approval', { id = long.id })
assert(page.truncated and page.next_start_line and #tools.execute('read_auto_approval', { id = long.id }) < 20000)
vim.fn.delete(temp, 'rf')
print('codeit auto-approval tracking and tools tests passed')
