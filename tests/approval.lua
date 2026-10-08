vim.opt.runtimepath:prepend(vim.fn.getcwd())
local approval = require('codeit.approval')
local original_select, original_input = vim.ui.select, vim.ui.input
local choices, inputs = {}, {}
local prompts = {}
vim.ui.select = function(options, opts, cb)
  prompts[#prompts + 1] = opts.prompt
  local choice = table.remove(choices, 1)
  if choice ~= false then assert(vim.tbl_contains(options, choice), tostring(choice)); cb(choice) else cb(nil) end
end
vim.ui.input = function(_, cb) cb(table.remove(inputs, 1)) end
local actions, result, signal = 0, nil, nil
local function call(name, args, context)
  result, signal = nil, nil
  approval.request(name, args, 'Review ' .. name, function() return true end,
    function(value, kind) result, signal = value, kind end,
    function() actions = actions + 1; result = 'executed' end, context)
end
approval.setup({ validators = {} })
call('read_file', { path = 'x' })
assert(result == 'executed' and actions == 1)
choices = { 'Reject' }; inputs = { 'do not expose this file' }
call('run_command', { argv = { 'echo', 'a' } })
assert(result == 'Rejected by user: do not expose this file' and actions == 1)
choices = { 'Always approve exact call' }
call('run_command', { argv = { 'echo', 'a' } })
assert(actions == 2)
call('run_command', { argv = { 'echo', 'a' } })
assert(actions == 3, 'remembered calls should not prompt')
choices = { 'Cancel task' }
call('run_command', { argv = { 'echo', 'b' } })
assert(signal == 'cancel' and actions == 3)
local reviews = 0
choices = { 'Ask reviewer', 'Ask another question', 'Back to approval', 'Approve once' }
inputs = { 'Is this safe?', 'What does it do?' }
call('run_command', { argv = { 'echo', 'c' } }, { user_request = 'test', review = function(history, cb)
  reviews = reviews + 1
  assert(history[1].role == 'system' and history[2].content:find('echo', 1, true))
  cb('This only prints text')
end })
assert(reviews == 2 and result == 'executed')
approval.setup({ validators = { function(name, args)
  if args.argv and args.argv[2] == 'a' then return 'reject', 'blocked' end
  if name == 'read_file' then return 'ask' end
end } })
call('run_command', { argv = { 'echo', 'a' } })
assert(result == 'Rejected by approval policy: blocked' and actions == 4)
choices = { false }
call('read_file', { path = 'x' })
assert(result == 'Rejected by user')
approval.setup({ validators = { function() error('bad policy') end } })
call('read_file', { path = 'x' })
assert(result:find('Validator error:', 1, true))
vim.ui.select, vim.ui.input = original_select, original_input
print('codeit approval tests passed')
