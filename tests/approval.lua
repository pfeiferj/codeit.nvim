vim.opt.runtimepath:prepend(vim.fn.getcwd())
local approval = require('codeit.approval')
local prompt_ui = require('codeit.approval_prompt')
local original_show, original_ask, original_input = prompt_ui.show, prompt_ui.ask_reviewer, vim.ui.input
local choices, inputs, questions = {}, {}, {}
local prompts = {}
local held_choice
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
  if choice == 'hold' then
    held_choice = cb
    local index = #prompts
    return function(updated) prompts[index] = updated end
  end
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
assert(prompts[#prompts]:find('# read_file\n\n```json\n{\n  "path": "x"\n}\n```', 1, true))
choices = { 'reject' }; inputs = { 'do not expose this file' }
call('run_command', { argv = { 'echo', 'a' } })
assert(prompts[#prompts]:find('# run_command\n\n```bash\necho a\n```', 1, true))
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
assert(not prompts[1]:find('Summary:', 1, true), 'read-only calls must not display a waiting summary')
local assessments = 0
local function assessed(answer, err)
  return { user_request = 'check command safety', review = function(history, cb)
    assessments = assessments + 1
    assert(history[1].role == 'system' and history[1].content:find('JSON object', 1, true))
    assert(history[2].content:find('check command safety', 1, true))
    cb(answer, err)
  end }
end
local function check_assessment(args, answer, expected, decision, err)
  choices = { 'hold' }
  inputs = { false }
  local pending
  call('run_command', args, { user_request = 'check command safety', review = function(history, cb)
    assessments = assessments + 1
    assert(history[1].content:find('JSON object', 1, true))
    pending = cb
  end })
  assert(prompts[#prompts]:find('Summary: Waiting for provider…', 1, true))
  assert(held_choice and pending and result == nil, 'approval must open before summary arrives')
  pending(answer, err)
  assert(prompts[#prompts]:find(expected, 1, true))
  held_choice(decision)
end
check_assessment({ argv = { 'echo', 'safe summary' } }, '{"summary":"Prints a message.","safe":true}',
  'Summary: Prints a message.', 'once')
check_assessment({ argv = { 'rm', '-rf', '/' } }, '{"summary":"Deletes all files.","safe":false}',
  '**Summary: Deletes all files.**', 'reject')
assert(result == 'Rejected by user', 'unsafe calls still require an explicit decision')
check_assessment({ argv = { 'echo', 'markdown' } }, '{"summary":"# Inject **heading** [link](url)","safe":false}',
  '**Summary: \\# Inject \\*\\*heading\\*\\* \\[link\\]\\(url\\)**', 'reject')
check_assessment({ argv = { 'echo', 'malformed' } }, 'not json',
  'Review unavailable (invalid response)', 'reject')
check_assessment({ argv = { 'echo', 'failed' } }, nil,
  'Review unavailable (reviewer error)', 'reject', 'offline')
assert(assessments == 5)
local workspace_buffer = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(workspace_buffer, vim.fn.getcwd() .. '/unsaved-workspace-file.lua')
local external_buffer = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(external_buffer, vim.fn.tempname())
local read_reviews = 0
local read_context = { review = function(_, cb)
  read_reviews = read_reviews + 1
  cb('{"summary":"Reads an external buffer.","safe":true}')
end }
read_context.source_buffer = workspace_buffer
assert(approval.prefetch('read_source_buffer', {}, read_context) == nil)
assert(approval.prefetch('search_workspace', { query = 'x' }, read_context) == nil)
read_context.source_buffer = external_buffer
local external_summary = approval.prefetch('read_source_buffer', {}, read_context)
assert(external_summary and read_reviews == 1)
external_summary(function(text) assert(text == 'Reads an external buffer.') end)
vim.api.nvim_buf_delete(workspace_buffer, { force = true })
vim.api.nvim_buf_delete(external_buffer, { force = true })
-- Only explicitly remembered or policy-approved calls skip the reviewer.
choices = { 'always' }
call('run_command', { argv = { 'echo', 'remembered review' } }, assessed('{"summary":"Prints text.","safe":true}'))
local count = assessments
call('run_command', { argv = { 'echo', 'remembered review' } }, assessed('unexpected'))
assert(assessments == count)
local pending, live = nil, true
choices = { 'hold' }
local before = #prompts
approval.request('run_command', { argv = { 'echo', 'stale review' } }, 'Review stale', function() return live end,
  function() error('inactive task completed') end, function() error('inactive task executed') end,
  { review = function(_, cb) pending = cb end })
assert(#prompts == before + 1 and pending, 'approval must open before the reviewer responds')
live = false
pending('{"summary":"Prints text.","safe":true}')
assert(prompts[#prompts]:find('Waiting for provider…', 1, true), 'stale reviewer response must not update approval')
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
