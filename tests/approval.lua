vim.opt.runtimepath:prepend(vim.fn.getcwd())
local approval = require('codeit.approval')
local prompt_ui = require('codeit.approval_prompt')
local original_show, original_ask, original_input = prompt_ui.show, prompt_ui.ask_reviewer, vim.ui.input
local choices, inputs, questions = {}, {}, {}
local prompts, prompt_configs, input_prompts = {}, {}, {}
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
  prompt_configs[#prompts] = config
  local choice = table.remove(choices, 1)
  if choice == 'hold' then
    held_choice = cb
    local index = #prompts
    return function(updated, updated_config)
      prompts[index] = updated
      prompt_configs[index] = updated_config
    end
  end
  if choice ~= false then
    assert(vim.tbl_contains(vim.tbl_map(function(option) return option.id end, options), choice), tostring(choice))
    cb(choice)
  else cb(nil) end
end
vim.ui.input = function(config, cb)
  input_prompts[#input_prompts + 1] = config.prompt
  cb(table.remove(inputs, 1))
end
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
call('run_command', { argv = { 'echo', 'a' } }, { review = function(_, cb)
  cb('{"summary":"Prints text.","safety_score":1}')
end })
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
    return cb('{"summary":"Prints text.","safety_score":1}')
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
  cb(history[1].content:find('JSON object', 1, true) and '{"summary":"Prints text.","safety_score":1}' or 'No issue')
end })
assert(result == 'Rejected by user', 'dismissing reviewer returns to approval')
choices = { 'review', 'once' }; questions = { 'Is this safe?' }
call('run_command', { argv = { 'echo', 'review back' } }, { review = function(history, cb)
  cb(history[1].content:find('JSON object', 1, true) and '{"summary":"Prints text.","safety_score":1}' or 'Yes')
end })
assert(result == 'executed')
local saved_ask, pending_review, review_active, late_answers = prompt_ui.ask_reviewer, nil, nil, 0
prompt_ui.ask_reviewer = function(_, _, ask, back)
  ask('Read more context', function() late_answers = late_answers + 1 end)
  back()
end
choices = { 'review', 'once' }
call('run_command', { argv = { 'echo', 'review pending' } }, { review = function(history, cb, feature, active)
  if feature == 'tool_assessment' then return cb('{"summary":"Prints text.","safety_score":1}') end
  pending_review, review_active = cb, active
  assert(active())
end })
assert(result == 'executed' and not review_active(), 'leaving reviewer must invalidate its pending tool loop')
pending_review('Late answer')
assert(late_answers == 0, 'closed reviewer must ignore late responses')
prompt_ui.ask_reviewer = saved_ask
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
check_assessment({ argv = { 'echo', 'safe summary' } }, '{"summary":"Prints a message.","safety_score":1}',
  'Summary: Prints a message.', 'once')
check_assessment({ argv = { 'rm', '-rf', '/' } }, '{"summary":"Deletes all files.","safety_score":10}',
  'Summary: Deletes all files.', 'reject')
assert(prompts[#prompts]:find('**Safety score:** 10/10', 1, true))
assert(prompt_configs[#prompts].safety_score == 10)
assert(result == 'Rejected by user', 'unsafe calls still require an explicit decision')
check_assessment({ argv = { 'echo', 'markdown' } }, '{"summary":"# Inject **heading** [link](url)","safety_score":7}',
  'Summary: \\# Inject \\*\\*heading\\*\\* \\[link\\]\\(url\\)', 'reject')
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
  cb('{"summary":"Reads an external buffer.","safety_score":1}')
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
call('run_command', { argv = { 'echo', 'remembered review' } }, assessed('{"summary":"Prints text.","safety_score":1}'))
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
pending('{"summary":"Prints text.","safety_score":1}')
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
call('edit_file', { path = 'example.lua', edits = { { old_text = 'before', new_text = 'after' } } }, {
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
-- Every score is displayed; only scores above 5 require typed confirmation.
for score = 0, 10 do
  choices = { 'hold' }
  call('run_command', { argv = { 'echo', 'score ' .. score } },
    assessed(vim.json.encode({ summary = 'Prints text.', safety_score = score })))
  assert(prompts[#prompts]:find('**Safety score:** ' .. score .. '/10', 1, true))
  assert(prompt_configs[#prompts].safety_score == score)
  local before_inputs = #input_prompts
  inputs = { 'APPROVE run_command' }
  held_choice('once')
  assert(result == 'executed')
  assert(#input_prompts == before_inputs + (score > 5 and 1 or 0))
end
-- Empty input, Enter, a single number, partial phrases, and cancellation cannot confirm.
for index, input in ipairs({ '', '\n', '1', 'APPROVE', 'approve run_command', false }) do
  choices, inputs = { 'hold' }, { input }
  call('run_command', { argv = { 'echo', 'accidental ' .. index } },
    assessed('{"summary":"Runs a risky command.","safety_score":6}'))
  local before_actions = actions
  held_choice('once')
  assert(result == 'Rejected: explicit confirmation did not match' and actions == before_actions)
end
-- Invalid, missing, legacy, fractional, and out-of-range scores remain unknown, not safe.
for index, answer in ipairs({
  'not json', '{"summary":"Prints text."}', '{"summary":"Prints text.","safe":true}',
  '{"summary":"Prints text.","safety_score":"1"}', '{"summary":"Prints text.","safety_score":null}',
  '{"summary":"Prints text.","safety_score":-1}', '{"summary":"Prints text.","safety_score":11}',
  '{"summary":"Prints text.","safety_score":1.5}', '{"summary":" ","safety_score":0}',
}) do
  choices, inputs = { 'hold' }, { '1' }
  call('run_command', { argv = { 'echo', 'invalid ' .. index } }, assessed(answer))
  assert(prompts[#prompts]:find('**Safety score:** Unavailable', 1, true))
  assert(prompt_configs[#prompts].risk_unknown)
  local before_actions = actions
  held_choice('once')
  assert(result == 'Rejected: explicit confirmation did not match' and actions == before_actions)
end
-- A failed or unconfigured assessment also needs the exact phrase.
for _, context in ipairs({ assessed(nil, 'offline'), {} }) do
  choices, inputs = { 'hold' }, { 'APPROVE run_command' }
  call('run_command', { argv = { 'echo', 'unknown' } }, context)
  held_choice('once')
  assert(result == 'executed' and prompt_configs[#prompts].risk_unknown)
end
-- High-risk and unknown approvals cannot be remembered.
for _, context in ipairs({ assessed('{"summary":"Risky.","safety_score":6}'), {} }) do
  for attempt = 1, 2 do
    choices, inputs = { 'hold' }, { 'APPROVE run_command' }
    local before_prompts = #prompts
    call('run_command', { argv = { 'echo', 'never remember ' .. tostring(context.review ~= nil) } }, context)
    assert(#prompts == before_prompts + 1)
    held_choice('always')
    assert(result == 'executed')
  end
end
-- Approving before the score arrives must not execute or remember the call.
local delayed
choices = { 'hold', 'hold' }
call('run_command', { argv = { 'echo', 'pending score' } }, { review = function(_, cb) delayed = cb end })
local before_actions, before_prompts = actions, #prompts
held_choice('always')
assert(actions == before_actions and result == nil and #prompts == before_prompts + 1)
delayed('{"summary":"Risky.","safety_score":6}')
inputs = { '1' }
held_choice('once')
assert(actions == before_actions and result == 'Rejected: explicit confirmation did not match')
-- Cancelling the task while the confirmation input is open invalidates its callback.
local confirmation, current = nil, true
vim.ui.input = function(_, cb) confirmation = cb end
choices = { 'hold' }
approval.request('run_command', { argv = { 'echo', 'cancel confirmation' } }, 'Confirm', function() return current end,
  function() error('inactive confirmation completed') end, function() error('inactive confirmation executed') end,
  assessed('{"summary":"Risky.","safety_score":6}'))
held_choice('once')
assert(confirmation)
current = false
confirmation('APPROVE run_command')
vim.ui.input, prompt_ui.show, prompt_ui.ask_reviewer = original_input, original_show, original_ask
print('codeit approval tests passed')
