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
plugin.setup({ context_review = false, max_context_tokens = false,
  model_presets = { fast = { model = 'fast-model' } } })
local tools, agents = require('codeit.tools'), require('codeit.tools.subagents')
local approval = require('codeit.tools.approval')
require('codeit.tools.approval.prompt').show = function() error('subagents must never prompt') end
vim.ui.input = function() error('subagents must never ask') end
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
for _, definition in ipairs(requests[2].specs) do assert(agents.allowed[definition['function'].name]) end
reply({ role = 'assistant', tool_calls = {
  call('read_file', { path = 'private.txt' }),
  call('run_command', { argv = { 'touch', 'bad' } }),
  call('ask_user', { question = 'Question?' }),
  call('start_subagent', { title = 'Nested', task = 'Nested', mode = 'background' }),
  call('write_subagent_artifact', { content = 'findings\nsecond line' }),
} })
await(3)
local messages = requests[3].messages
assert(messages[#messages - 4].content:find('requires approval', 1, true))
for i = #messages - 3, #messages - 1 do assert(messages[i].content:find('not available', 1, true)) end
local artifact = vim.json.decode(messages[#messages].content)
assert(vim.fn.readfile(artifact.path)[1] == 'findings')
assert(vim.fn.filereadable(temp .. '/bad') == 0)
reply({ role = 'assistant', content = 'Found useful information' }, { cost = 0.25, prompt_tokens = 10, completion_tokens = 5 })
assert(agents.list()[1].status == 'completed')
assert(#requests == 4, 'wait result resumes main agent')
assert(requests[4].messages[#requests[4].messages].content:find('Found useful information', 1, true))
reply({ role = 'assistant', content = 'Done' })
local result
local function execute(name, args, context)
  result = nil
  tools.execute(name, args, nil, function(value) result = value end, nil, context)
  assert(result)
  return result
end
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
assert(execute('create_file', { path = 'bad', content = 'bad' }, { no_prompt = true }):find('not available', 1, true))
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
await(5)
reply({ role = 'assistant', content = 'Background results' })
vim.wait(250, function() return false end)
assert(#sent == 0)
idle = true
assert(vim.wait(1000, function() return #sent == 1 end))
vim.wait(250, function() return false end)
assert(#sent == 1)
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
assert(vim.wait(1000, function() return agents.list()[6].status == 'failed' end))
agents.start({ title = 'Failure', task = 'Fail', mode = 'background' }, nil, context, function() end)
await(11)
table.remove(callbacks, 1)(nil, 'Provider failure')
assert(agents.list()[7].status == 'failed')
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
agents.shutdown()
assert(vim.fn.filereadable(artifact.path) == 0 and vim.fn.isdirectory(vim.fn.fnamemodify(artifact.path, ':h')) == 0)
vim.fn.chdir(vim.fn.fnamemodify(temp, ':h'))
vim.fn.delete(temp, 'rf')
print('codeit subagent tests passed')
