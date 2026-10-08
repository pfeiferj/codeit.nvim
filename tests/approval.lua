vim.opt.runtimepath:prepend(vim.fn.getcwd())
local approval = require('codeit.approval')
local prompt_ui = require('codeit.approval_prompt')
local original_show, original_ask, original_input = prompt_ui.show, prompt_ui.ask_reviewer, vim.ui.input
local choices, inputs, questions = {}, {}, {}
local prompts = {}
prompt_ui.ask_reviewer = function(name, args, cb)
  assert(name == 'run_command' and args:find('echo', 1, true), 'review question must show the tool call')
  cb(table.remove(questions, 1))
end
prompt_ui.show = function(prompt, options, cb, config)
  prompts[#prompts + 1] = prompt
  for i, option in ipairs(options) do assert(option.key == tostring(i), 'options must use consecutive number keys') end
  if config then assert(config.title == ' Tool-call reviewer ' and config.dismiss == 'Back to approval') end
  local choice = table.remove(choices, 1)
  if choice ~= false then
    assert(vim.tbl_contains(vim.tbl_map(function(option) return option.id end, options), choice), tostring(choice))
    cb(choice)
  else cb(nil) end
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
choices = { 'once' }
call('read_file', { path = 'x' })
assert(result == 'executed' and actions == 1 and #prompts == 1)
choices = { 'reject' }; inputs = { 'do not expose this file' }
call('run_command', { argv = { 'echo', 'a' } })
assert(result == 'Rejected by user: do not expose this file' and actions == 1)
choices = { 'always' }
call('run_command', { argv = { 'echo', 'a' } })
assert(actions == 2)
call('run_command', { argv = { 'echo', 'a' } })
assert(actions == 3, 'remembered calls should not prompt')
choices = { 'cancel' }
call('run_command', { argv = { 'echo', 'b' } })
assert(signal == 'cancel' and actions == 3)
local reviews = 0
choices = { 'review', 'again', 'back', 'once' }
questions = { 'Is this safe?', 'What does it do?' }
call('run_command', { argv = { 'echo', 'c' } }, { user_request = 'test', review = function(history, cb)
  reviews = reviews + 1
  assert(history[1].role == 'system' and history[2].content:find('echo', 1, true))
  cb('This only prints text')
end })
assert(reviews == 2 and result == 'executed')
assert(prompts[#prompts - 1]:find('Question: What does it do?', 1, true))
assert(prompts[#prompts - 1]:find('Reviewer: This only prints text', 1, true))
choices = { 'review', false, 'reject' }; questions = { 'Another question?', false }
call('run_command', { argv = { 'echo', 'review escape' } }, { review = function(_, cb) cb('No issue') end })
assert(result == 'Rejected by user', 'dismissing reviewer returns to approval')
choices = { 'review', 'back', 'once' }; questions = { 'Is this safe?' }
call('run_command', { argv = { 'echo', 'review back' } }, { review = function(_, cb) cb('Yes') end })
assert(result == 'executed')
-- Trust from a read approval persists for this workspace and auto-approves future reads only.
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
vim.fn.writefile({ 'tracked' }, dir .. '/tracked.txt')
vim.fn.writefile({ 'untracked' }, dir .. '/untracked.txt')
assert(vim.fn.system({ 'git', '-C', dir, 'init', '-q' }) == '')
assert(vim.fn.system({ 'git', '-C', dir, 'add', 'tracked.txt' }) == '')
local cwd = vim.fn.getcwd()
vim.cmd.cd(dir)
choices = { 'tracked' }
call('read_file', { path = 'tracked.txt' })
assert(result == 'executed' and approval.workspace_trust() == 'tracked')
local count = #prompts
call('read_file', { path = 'tracked.txt' })
assert(result == 'executed' and #prompts == count)
choices = { 'all' }
call('read_file', { path = 'untracked.txt' })
assert(approval.workspace_trust() == 'all')
approval.setup({})
assert(approval.workspace_trust() == 'all', 'prompt trust should persist')
choices = { 'reject' }; inputs = { false }
call('run_command', { argv = { 'echo', 'trust does not approve commands' } })
assert(result == 'Rejected by user')
assert(approval.set_workspace_trust(nil))
vim.cmd.cd(cwd)
vim.fn.delete(dir, 'rf')
approval.setup({ validators = { function(name, args)
  if args.argv and args.argv[2] == 'a' then return 'reject', 'blocked' end
  if name == 'read_file' then return 'ask' end
end } })
call('run_command', { argv = { 'echo', 'a' } })
assert(result == 'Rejected by approval policy: blocked')
choices = { false }
call('read_file', { path = 'x' })
assert(result == 'Rejected by user')
approval.setup({ validators = { function() error('bad policy') end } })
call('read_file', { path = 'x' })
assert(result:find('Validator error:', 1, true))
vim.ui.input, prompt_ui.show, prompt_ui.ask_reviewer = original_input, original_show, original_ask
print('codeit approval tests passed')
