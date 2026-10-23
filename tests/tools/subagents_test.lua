vim.opt.runtimepath:prepend(vim.fn.getcwd())
local requests, callbacks = {}, {}
package.loaded['codeit.providers'] = {
  chat = function(config, messages, specs, callback, _, active)
    requests[#requests + 1] = { config = vim.deepcopy(config), messages = vim.deepcopy(messages), specs = specs, active = active }
    callbacks[#callbacks + 1] = callback
  end,
}
local temp = vim.fn.tempname()
vim.fn.mkdir(temp, 'p')
vim.fn.chdir(temp)
vim.fn.writefile({ 'private' }, temp .. '/private.txt')
local plugin = require('codeit')
plugin.setup({ context_review = false, max_context_tokens = false, max_tool_rounds = 1,
  model_presets = { fast = { model = 'fast-model' } } })
local tools, agents = require('codeit.tools'), require('codeit.tools.subagents')
local approval = require('codeit.tools.approval')
local approval_prompts = 0
require('codeit.tools.approval.prompt').show = function(_, _, callback)
  approval_prompts = approval_prompts + 1
  callback(nil)
end
require('codeit.tools.limit_prompt').show = function() error('subagents must never extend their budget') end
require('codeit.ui.input').show = function() error('subagents must never ask') end
vim.ui.select = function() error('subagents must never select') end
local function reply(message, usage)
  table.remove(callbacks, 1)(message, nil, usage)
end
local function call(name, args)
  return { id = name, type = 'function', ['function'] = { name = name, arguments = vim.json.encode(args) } }
end
local function await(count)
  assert(vim.wait(1000, function() return #requests >= count end))
end
assert(tools.validate('start_subagent', { title = 'x', task = 'x', mode = 'invalid' }))
assert(require('codeit.settings').feature_presets.subagent == 'fast')
plugin.send('Delegate a task')
reply({ role = 'assistant', tool_calls = { call('start_subagent', { title = 'Research', task = 'Inspect safely', mode = 'wait' }) } })
assert(#requests == 1, 'wait must not return early: ' .. vim.inspect(requests[#requests].messages))
await(2)
assert(requests[2].config.model == 'fast-model')
assert(requests[2].config.max_tool_rounds == 40, 'subagents must not inherit the main chat limit')
local advertised = {}
for _, definition in ipairs(requests[2].specs) do
  local name = definition['function'].name
  assert(agents.allowed(name))
  advertised[name] = true
end
for name in pairs(require('codeit.tools.windows').names) do
  assert(advertised[name], 'subagents must have window tool ' .. name)
end
for _, name in ipairs({ 'edit_file', 'save_buffer', 'create_file', 'run_command', 'fetch_url', 'ask_user' }) do
  assert(advertised[name], 'subagents must have main-chat tool ' .. name)
end
for _, name in ipairs({ 'start_subagent', 'get_subagent', 'get_subagent_status', 'cancel_subagent', 'start_background_task' }) do
  assert(not advertised[name], 'subagents must not have tool ' .. name)
end
local prompt = requests[2].messages[#requests[2].messages - 1].content
assert(prompt:find('window-management tools', 1, true))
assert(prompt:find('minimize non-read-only calls', 1, true))
assert(require('codeit.settings.defaults').system_prompt:find('delegating bounded window-management tasks', 1, true))
reply({ role = 'assistant', tool_calls = {
  call('read_file', { path = 'private.txt' }),
  call('start_background_task', { argv = { 'touch', 'bad' }, title = 'Forbidden' }),
  call('get_subagent', { run_id = 1 }),
  call('start_subagent', { title = 'Nested', task = 'Nested', mode = 'background' }),
  call('write_subagent_artifact', { content = 'findings\nsecond line' }),
} })
await(3)
local messages = requests[3].messages
assert(messages[#messages - 4].content:find('Rejected', 1, true))
assert(approval_prompts == 1, 'untrusted reads must request approval')
for i = #messages - 3, #messages - 1 do assert(messages[i].content:find('not available', 1, true)) end
local artifact = vim.json.decode(messages[#messages].content)
assert(vim.fn.readfile(artifact.path)[1] == 'findings')
assert(vim.fn.filereadable(temp .. '/bad') == 0)
reply({ role = 'assistant', content = 'Found useful information',
  reasoning = 'private reasoning', reasoning_details = { { text = 'private reasoning details' } },
  _codex_reasoning = { { encrypted_content = 'private encrypted reasoning' } },
}, { cost = 0.25, prompt_tokens = 10, completion_tokens = 5 })
assert(agents.list()[1].status == 'completed')
assert(#requests == 4, 'wait result resumes main agent')
local wait_result = vim.json.decode(requests[4].messages[#requests[4].messages].content)
assert(wait_result.result == 'Found useful information' and not wait_result.messages)
assert(not vim.json.encode(wait_result):find('private', 1, true))
reply({ role = 'assistant', content = 'Done' })
local result
local function execute(name, args, context)
  result = nil
  tools.execute(name, args, nil, function(value) result = value end, nil, context)
  assert(result)
  return result
end
-- Window management is approval-free, but assistant attachments do not grant read trust.
local function window_call(name, args)
  local value = execute(name, args, { no_prompt = true })
  assert(not value:find('Error:', 1, true), value)
  return vim.json.decode(value)
end
local ui = require('codeit.ui')
ui.open(function() end, ui.close)
local file_win = window_call('list_windows', {}).windows[1].window_id
local opened = window_call('open_window_file', { window_id = file_win, path = 'private.txt' })
assert(execute('read_window_buffer', { window_id = file_win }, { no_prompt = true }):find('requires approval', 1, true))
local edited = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(edited, 0, -1, false, { 'unsaved', 'second line' })
window_call('open_window_buffer', { window_id = file_win, buffer_id = edited })
local split = window_call('split_window', { window_id = file_win, direction = 'vertical' })
window_call('open_window_buffer', { window_id = split.window_id, buffer_id = opened.buffer_id })
window_call('close_window', { window_id = split.window_id })
split = window_call('split_window_file', { window_id = file_win, path = 'private.txt' })
window_call('close_window', { window_id = split.window_id })
split = window_call('split_window_buffer', { window_id = file_win, buffer_id = edited })
window_call('resize_window', { window_id = split.window_id, height = 5 })
local cursor = window_call('set_window_cursor', { window_id = split.window_id, line = 2, center = false })
assert(cursor.cursor_line == 2)
window_call('scroll_window', { window_id = split.window_id, lines = 1 })
window_call('focus_window', { window_id = split.window_id })
assert(vim.api.nvim_get_current_win() == split.window_id)
window_call('close_window', { window_id = split.window_id })
assert(vim.bo[edited].modified and vim.api.nvim_buf_get_lines(edited, 0, 1, false)[1] == 'unsaved')
local function assert_status(run_id, status)
  local data = vim.json.decode(execute('get_subagent_status', { run_id = run_id }))
  assert(vim.deep_equal(data, { status = status }), 'status polling must return only status')
end
assert(not tools.validate('get_subagent_status', { run_id = 1 }))
assert(tools.validate('get_subagent_status', { run_id = 0 }))
assert(tools.validate('get_subagent_status', {}))
assert_status(1, 'completed')
assert(execute('get_subagent_status', { run_id = 999 }):find('unknown subagent run', 1, true))
local data = vim.json.decode(execute('read_subagent_artifact', { run_id = 1, artifact_id = 1, start_line = 2 }))
assert(data.lines[1] == 'second line')
assert(execute('write_subagent_artifact', { content = 'no' }):find('only running subagents', 1, true))
assert(execute('read_subagent_artifact', { run_id = 1, artifact_id = 99 }):find('unknown artifact', 1, true))
-- Trust and validators still apply, including explicit asks and rejections.
approval.setup({ trusted_workspaces = { [temp] = 'all' } })
assert(execute('read_file', { path = 'private.txt' }, { no_prompt = true }):find('private', 1, true))
approval.setup({ trusted_workspaces = { [temp] = 'all' }, validators = { function() return 'ask' end } })
assert(execute('read_file', { path = 'private.txt' }, { no_prompt = true }):find('requires approval', 1, true))
approval.setup({ validators = { function() return 'approve' end } })
assert(execute('start_background_task', { argv = { 'touch', 'bad' }, title = 'Forbidden' },
  { subagent_run = agents.list()[1] }):find('not available', 1, true))
assert(execute('start_subagent', { title = 'Nested', task = 'Nested', mode = 'wait' },
  { subagent_run = agents.list()[1] }):find('not available', 1, true))
approval.setup({ validators = { function() return 'reject' end } })
assert(execute('read_file', { path = 'private.txt' }, { no_prompt = true }):find('Rejected', 1, true))
approval.setup({})
local idle, sent = false, {}
agents.configure(function(run) return idle and run.origin.chat_id == 'origin' end,
  function(_, text) sent[#sent + 1] = text end)
local context = { subagent_config = { provider = 'openrouter', model = 'test', max_tool_rounds = 1 },
  background_origin = { workspace = temp, chat_id = 'origin' } }
local returned
agents.start({ title = 'Notify', task = 'Summarize', mode = 'background_notify' }, nil, context,
  function(value) returned = value end, function() return false end)
assert(returned and agents.list()[2].status == 'running')
assert_status(2, 'running')
await(5)
reply({ role = 'assistant', content = {
  { type = 'text', text = 'Background results' },
  { type = 'reasoning', text = 'private structured reasoning' },
  { type = 'tool_call', name = 'private tool', arguments = 'private arguments' },
  { type = 'text', text = 'Second finding' },
} })
vim.wait(250, function() return false end)
assert(#sent == 0)
idle = true
assert(vim.wait(1000, function() return #sent == 1 end))
vim.wait(250, function() return false end)
assert(#sent == 1)
assert(sent[1]:find('Background results\\nSecond finding', 1, true))
assert(not sent[1]:find('private', 1, true))
assert_status(2, 'completed')
assert(vim.json.decode(execute('get_subagent', { run_id = 2 })).result == 'Background results\nSecond finding')
agents.start({ title = 'Quiet', task = 'Summarize', mode = 'background' }, nil, context, function() end)
await(6)
reply({ role = 'assistant', content = 'Quiet results' })
vim.wait(250, function() return false end)
assert(#sent == 1 and not agents.list()[3].notification)
-- Cancel from the UI and ignore late provider responses.
agents.start({ title = 'Cancel', task = 'Wait', mode = 'background' }, nil, context, function() end)
await(7)
agents.show()
local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
local function press(key)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do if map.lhs == key then map.callback(); return end end
  error('missing mapping ' .. key)
end
vim.api.nvim_win_set_cursor(win, { 3, 0 })
press('<CR>')
assert(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'):find('Found useful information', 1, true))
press('<CR>')
vim.api.nvim_win_set_cursor(win, { 6, 0 })
press('c')
assert(agents.list()[4].status == 'cancelled' and not requests[7].active())
assert_status(4, 'cancelled')
reply({ role = 'assistant', content = 'Too late' })
assert(agents.list()[4].result == 'Cancelled')
press('q')
local live = true
agents.start({ title = 'Parent stop', task = 'Wait', mode = 'wait' }, nil, context, function() end, function() return live end)
await(8)
live = false
assert(not requests[8].active() and agents.list()[5].status == 'cancelled')
reply({ role = 'assistant', content = 'Ignored' })
-- Failure and round limits are terminal and never ask for a budget extension.
agents.start({ title = 'Limit', task = 'Loop', mode = 'background' }, nil, context, function() end)
await(9)
reply({ role = 'assistant', tool_calls = { call('get_diagnostics', {}) } })
await(10)
reply({ role = 'assistant', tool_calls = { call('get_diagnostics', {}) } })
assert(agents.list()[6].status == 'failed' and agents.list()[6].result == 'Subagent tool round limit reached')
local tool_results = 0
for _, message in ipairs(agents.list()[6].messages) do
  if message.role == 'tool' then tool_results = tool_results + 1 end
end
assert(tool_results == 1, 'the batch beyond the hard limit must not execute')
agents.start({ title = 'Failure', task = 'Fail', mode = 'background' }, nil, context, function() end)
await(11)
table.remove(callbacks, 1)(nil, 'Provider failure')
assert(agents.list()[7].status == 'failed')
assert_status(7, 'failed')
-- Feature overrides and billing remain associated with the originating chat.
local settings = plugin.get_settings()
settings.feature_settings.subagent = { provider = 'copilot', model = 'override-model' }
assert(plugin.configure(settings))
plugin.new()
plugin.send('Background billing')
reply({ role = 'assistant', tool_calls = { call('start_subagent', { title = 'Billing', task = 'Research', mode = 'background' }) } })
reply({ role = 'assistant', content = 'Started' })
await(14)
assert(requests[14].config.provider == 'copilot' and requests[14].config.model == 'override-model')
local history = require('codeit.chat.storage')
local origin_id = agents.list()[8].origin.chat_id
local before_cost = history.load(temp, origin_id).cost
plugin.new()
plugin.send('Different chat')
reply({ role = 'assistant', content = 'Billed to origin' }, { cost = 0.5, prompt_tokens = 11, completion_tokens = 7 })
reply({ role = 'assistant', content = 'Other reply' }, { cost = 0, prompt_tokens = 1, completion_tokens = 1 })
local origin_chat = history.load(temp, origin_id)
assert(origin_chat.cost == before_cost + 0.5)
assert(origin_chat.cost_by_function.subagent.cost == 0.5)
assert(origin_chat.turn_costs[1].cost_by_function.subagent.cost == 0.5)
local active_chat = history.load(temp, history.list(temp)[1].id)
assert(active_chat.cost == 0 and not active_chat.cost_by_function.subagent)
-- Switching workspaces never allows reads from the new cwd.
agents.start({ title = 'Workspace change', task = 'Read', mode = 'background' }, nil, context, function() end)
await(16)
vim.fn.chdir(vim.fn.fnamemodify(temp, ':h'))
reply({ role = 'assistant', tool_calls = { call('read_file', { path = 'private.txt' }) } })
assert(agents.list()[9].status == 'failed')
vim.fn.chdir(temp)
-- Every result delivery path exposes display text only, including failures.
local function start_result_case(mode)
  local count = #requests + 1
  local id = #agents.list() + 1
  local delivered
  agents.start({ title = 'Display only', task = 'Summarize', mode = mode }, nil, context,
    function(value) delivered = value end)
  await(count)
  return id, function() return delivered end
end
local id, delivered = start_result_case('wait')
reply({ role = 'assistant', content = vim.NIL, refusal = 'Cannot help with that',
  reasoning = 'private refusal reasoning' })
assert(vim.json.decode(delivered()).result == 'Cannot help with that')
assert(vim.json.decode(execute('get_subagent', { run_id = id })).result == 'Cannot help with that')

local raw_failure = vim.json.encode({ messages = requests[#requests].messages,
  reasoning = 'private failure reasoning', tool_calls = { call('get_diagnostics', {}) } })
id, delivered = start_result_case('wait')
table.remove(callbacks, 1)(nil, raw_failure, nil, raw_failure)
local failure_result = vim.json.decode(delivered())
assert(failure_result.status == 'failed' and failure_result.result == 'Subagent provider request failed')
assert(execute('get_subagent', { run_id = id }) == delivered())
assert(not delivered():find('private', 1, true) and not failure_result.messages)

local notification_count = #sent
id = start_result_case('background_notify')
table.remove(callbacks, 1)(nil, raw_failure)
assert(vim.wait(1000, function() return #sent > notification_count end))
assert(sent[#sent]:find('Subagent provider request failed', 1, true))
assert(not sent[#sent]:find('private', 1, true))

-- Exceptions must not dump request context into wait results either.
local provider = package.loaded['codeit.providers']
local chat = provider.chat
provider.chat = function() error(raw_failure) end
local exception_result
agents.start({ title = 'Exception', task = 'Fail', mode = 'wait' }, nil, context,
  function(value) exception_result = value end)
assert(vim.wait(1000, function() return exception_result ~= nil end))
assert(vim.json.decode(exception_result).result == 'Subagent provider request failed')
assert(not exception_result:find('private', 1, true))
provider.chat = chat

-- Tool errors, including executor exceptions, stay within the subagent and allow retries.
approval.setup({ trusted_workspaces = { [temp] = 'all' } })
local recovery_context = vim.deepcopy(context)
recovery_context.subagent_config.max_tool_rounds = 2
local original_execute = tools.execute
tools.execute = function(name, args, ...)
  if name == 'read_file' and args.path == 'throw.txt' then error('read failed: temporary tool exception') end
  return original_execute(name, args, ...)
end
local count = #requests + 1
local recovered
id = #agents.list() + 1
agents.start({ title = 'Recover', task = 'Read a file', mode = 'wait' }, nil, recovery_context,
  function(value) recovered = value end)
await(count)
local malformed = call('read_file', {})
malformed.id, malformed['function'].arguments = 'malformed', '{invalid json'
local thrown = call('read_file', { path = 'throw.txt' })
thrown.id = 'thrown'
reply({ role = 'assistant', tool_calls = { malformed, thrown,
  call('read_file', { path = 'private.txt', start_line = 2, end_line = 1 }) } })
await(count + 1)
assert(agents.list()[id].status == 'running' and not recovered)
local errors = requests[#requests].messages
assert(errors[#errors - 2].content:find('invalid tool arguments:', 1, true))
assert(errors[#errors - 1].content:find('temporary tool exception', 1, true))
assert(errors[#errors].content == 'Error: invalid range', errors[#errors].content)
reply({ role = 'assistant', tool_calls = { call('read_file', { path = 'private.txt' }) } })
await(count + 2)
assert(requests[#requests].messages[#requests[#requests].messages].content:find('private', 1, true))
reply({ role = 'assistant', content = 'Recovered successfully' })
assert(vim.json.decode(recovered).status == 'completed' and vim.json.decode(recovered).result == 'Recovered successfully')
assert(not recovered:find('temporary tool exception', 1, true))
tools.execute = original_execute

-- A zero budget allows a final answer but rejects the first tool batch.
context.subagent_config.max_tool_rounds = 0
id, delivered = start_result_case('wait')
reply({ role = 'assistant', content = 'No tools needed' })
assert(vim.json.decode(delivered()).status == 'completed')
id, delivered = start_result_case('wait')
reply({ role = 'assistant', tool_calls = { call('write_subagent_artifact', { content = 'must not write' }) } })
assert(vim.json.decode(delivered()).result == 'Subagent tool round limit reached')
assert(#agents.list()[id].artifacts == 0)
context.subagent_config.max_tool_rounds = 1

-- Custom budgets propagate separately and permit more rounds than the main chat.
plugin.setup({ context_review = false, max_context_tokens = false,
  max_tool_rounds = 1, max_subagent_tool_rounds = 2 })
count = #requests + 1
plugin.send('Delegate with a custom budget')
reply({ role = 'assistant', tool_calls = { call('start_subagent', { title = 'Custom budget', task = 'Inspect', mode = 'wait' }) } })
await(count + 1)
assert(requests[#requests].config.max_tool_rounds == 2)
for round = 1, 2 do
  reply({ role = 'assistant', tool_calls = { call('get_diagnostics', {}) } })
  await(count + 1 + round)
end
reply({ role = 'assistant', content = 'Two rounds completed' })
reply({ role = 'assistant', content = 'Done' })
assert(agents.list()[#agents.list()].status == 'completed')
for _, invalid in ipairs({ -1, 0.5, '40', math.huge }) do
  local ok, err = pcall(plugin.setup, { max_subagent_tool_rounds = invalid })
  assert(not ok and tostring(err):find('max_subagent_tool_rounds must be a nonnegative whole number', 1, true))
end
agents.shutdown()
assert(vim.fn.filereadable(artifact.path) == 0 and vim.fn.isdirectory(vim.fn.fnamemodify(artifact.path, ':h')) == 0)
vim.fn.chdir(vim.fn.fnamemodify(temp, ':h'))
vim.fn.delete(temp, 'rf')
print('codeit subagent tests passed')
