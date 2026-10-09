vim.opt.runtimepath:prepend(vim.fn.getcwd())
local approval = require('codeit.approval')
local prompt_ui = require('codeit.approval_prompt')
local original_show, original_ask, original_input = prompt_ui.show, prompt_ui.ask_reviewer, vim.ui.input
local choices, inputs, questions = {}, {}, {}
local prompts = {}
local reviewer_sessions = 0
prompt_ui.ask_reviewer = function(name, args, ask, back)
  reviewer_sessions = reviewer_sessions + 1
  assert(name == 'run_command' and args:find('echo', 1, true), 'review question must show the tool call')
  while #questions > 0 do
    local question = table.remove(questions, 1)
    if not question then break end
    ask(question, function(answer) assert(type(answer) == 'string') end)
  end
  back()
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
choices = { 'review', 'once' }
questions = { 'Is this safe?', 'What does it do?' }
call('run_command', { argv = { 'echo', 'c' } }, { user_request = 'test', review = function(history, cb)
  if history[1].content:find('JSON object', 1, true) then
    return cb('{"summary":"Prints text.","safe":true}')
  end
  reviews = reviews + 1
  assert(history[1].role == 'system' and history[2].content:find('echo', 1, true))
  if reviews == 2 then
    assert(history[3].role == 'user' and history[3].content == 'Is this safe?')
    assert(history[4].role == 'assistant' and history[4].content == 'This only prints text')
    assert(history[5].role == 'user' and history[5].content == 'What does it do?')
  end
  cb('This only prints text')
end })
assert(reviews == 2 and result == 'executed' and reviewer_sessions == 1)
choices = { 'review', 'reject' }; questions = { 'Another question?' }
call('run_command', { argv = { 'echo', 'review escape' } }, { review = function(history, cb)
  cb(history[1].content:find('JSON object', 1, true) and '{"summary":"Prints text.","safe":true}' or 'No issue')
end })
assert(result == 'Rejected by user', 'dismissing reviewer returns to approval')
choices = { 'review', 'once' }; questions = { 'Is this safe?' }
call('run_command', { argv = { 'echo', 'review back' } }, { review = function(history, cb)
  cb(history[1].content:find('JSON object', 1, true) and '{"summary":"Prints text.","safe":true}' or 'Yes')
end })
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
approval.setup({})
assert(prompts[1]:find('Summary: Review unavailable (reviewer not configured)', 1, true))
local assessments = 0
local function assessed(answer, err)
  return { user_request = 'check command safety', review = function(history, cb)
    assessments = assessments + 1
    assert(history[1].role == 'system' and history[1].content:find('JSON object', 1, true))
    assert(history[2].content:find('check command safety', 1, true))
    cb(answer, err)
  end }
end
choices = { 'once' }
call('run_command', { argv = { 'echo', 'safe summary' } }, assessed('{"summary":"Prints a message.","safe":true}'))
assert(prompts[#prompts]:find('Summary: Prints a message.', 1, true))
assert(not prompts[#prompts]:find('**Summary:', 1, true))
choices = { 'reject' }; inputs = { false }
call('run_command', { argv = { 'rm', '-rf', '/' } }, assessed('{"summary":"Deletes all files.","safe":false}'))
assert(prompts[#prompts]:find('**Summary: Deletes all files.**', 1, true))
assert(result == 'Rejected by user', 'unsafe calls still require an explicit decision')
choices = { 'reject' }; inputs = { false }
call('run_command', { argv = { 'echo', 'markdown' } }, assessed('{"summary":"# Inject **heading** [link](url)","safe":false}'))
assert(prompts[#prompts]:find('**Summary: \\# Inject \\*\\*heading\\*\\* \\[link\\]\\(url\\)**', 1, true))
choices = { 'reject' }; inputs = { false }
call('run_command', { argv = { 'echo', 'malformed' } }, assessed('not json'))
assert(prompts[#prompts]:find('Review unavailable (invalid response)', 1, true))
choices = { 'reject' }; inputs = { false }
call('run_command', { argv = { 'echo', 'failed' } }, assessed(nil, 'offline'))
assert(prompts[#prompts]:find('Review unavailable (reviewer error)', 1, true))
assert(assessments == 5)
-- Only explicitly remembered or policy-approved calls skip the reviewer.
choices = { 'always' }
call('run_command', { argv = { 'echo', 'remembered review' } }, assessed('{"summary":"Prints text.","safe":true}'))
local count = assessments
call('run_command', { argv = { 'echo', 'remembered review' } }, assessed('unexpected'))
assert(assessments == count)
local pending, live = nil, true
local before = #prompts
approval.request('run_command', { argv = { 'echo', 'stale review' } }, 'Review stale', function() return live end,
  function() error('inactive task completed') end, function() error('inactive task executed') end,
  { review = function(_, cb) pending = cb end })
assert(#prompts == before and pending, 'wait for the reviewer before prompting')
live = false
pending('{"summary":"Prints text.","safe":true}')
assert(#prompts == before, 'stale reviewer response must not open approval')
local write_ui = require('codeit.write_approval')
local old_write_show = write_ui.show
local write_calls = 0
write_ui.show = function(diff, options, cb)
  write_calls = write_calls + 1
  assert(diff.path == 'example.lua' and diff.before == 'before\n' and diff.after == 'after\n')
  assert(options[5].id == 'review')
  cb(write_calls == 1 and 'review' or 'once')
end
prompt_ui.ask_reviewer = function(_, _, ask, back)
  ask('Is the change safe?', function(answer) assert(answer == 'The change is small.') end)
  back()
end
local review_calls = 0
choices = {}
call('edit_file', { path = 'example.lua', old_text = 'before', new_text = 'after' }, {
  diff = { path = 'example.lua', before = 'before\n', after = 'after\n' },
  review = function(history, cb)
    review_calls = review_calls + 1
    assert(history[2].content:find('Proposed unified diff:', 1, true))
    assert(history[2].content:find('-before\n+after', 1, true))
    cb('The change is small.')
  end,
})
assert(result == 'executed' and write_calls == 2 and review_calls == 1)
write_ui.show = old_write_show
vim.ui.input, prompt_ui.show, prompt_ui.ask_reviewer = original_input, original_show, original_ask
print('codeit approval tests passed')
