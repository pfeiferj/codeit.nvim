vim.opt.runtimepath:prepend(vim.fn.getcwd())
local requests, callbacks, streams, active = {}, {}, {}, {}
package.loaded['codeit.providers'] = {
  chat = function(_, messages, _, callback, stream, is_active)
    requests[#requests + 1] = vim.deepcopy(messages)
    callbacks[#callbacks + 1] = callback
    streams[#requests] = stream
    active[#requests] = is_active
  end,
}
local plugin = require('codeit')
plugin.setup({ context_review = false })
local tasks = require('codeit.tools.execution.tasks')
local approval = require('codeit.tools.approval')
local approve
approval.prefetch = function() end
approval.request = function(_, _, _, _, _, action) approve = action end
local selections, choices = 0, {}
vim.ui.select = function(_, _, callback)
  selections = selections + 1
  choices[#choices + 1] = callback
end
local function reply(message)
  table.remove(callbacks, 1)(message)
end
plugin.send('Run a slow task')
reply({ role = 'assistant', tool_calls = { {
  id = 'background', type = 'function', ['function'] = {
    name = 'start_background_task', arguments = vim.json.encode({
      argv = { 'sh', '-c', 'printf live; sleep 0.5; printf done; printf err >&2' },
      title = 'Slow task', notify_on_completion = true,
    }),
  },
} } })
assert(approve and #tasks.list() == 0, 'must not start before approval')
approve()
assert(#tasks.list() == 1 and tasks.list()[1].status == 'running')
assert(requests[2][#requests[2]].content:find('task_id', 1, true), 'returns immediately')
reply({ role = 'assistant', content = 'Task started' })
plugin.send('Another prompt while running')
assert(#requests == 3, 'background task must not keep chat busy')
local task = tasks.list()[1]
assert(vim.wait(400, function() return task.log:find('live', 1, true) ~= nil end), 'live logs')
assert(vim.wait(3000, function() return task.status == 'completed' end))
assert(task.log:find('done', 1, true) and task.log:find('err', 1, true), 'both streams')
vim.wait(300, function() return false end)
assert(selections == 0, 'completion must wait while assistant is busy')
reply({ role = 'assistant', content = 'Second reply' })
assert(vim.wait(1000, function() return selections == 1 end))
plugin.new()
choices[1]('Send results to assistant')
vim.wait(300, function() return false end)
assert(#requests == 3, 'approval must not send results to another chat')

plugin.send('Run a task and keep working')
reply({ role = 'assistant', tool_calls = { {
  id = 'interrupting-background', type = 'function', ['function'] = {
    name = 'start_background_task', arguments = vim.json.encode({
      argv = { 'sh', '-c', 'sleep 0.2; printf immediate' },
      title = 'Interrupting task', notify_on_completion = true,
    }),
  },
} } })
approve()
local immediate = tasks.list()[2]
local pending_request = #requests
streams[pending_request]('Working on something else')
assert(vim.wait(3000, function() return immediate.status == 'completed' end))
assert(immediate.notification == 'pending')
vim.wait(300, function() return false end)
assert(selections == 1, 'originating turn completion must not ask for approval')
assert(#requests == pending_request and active[pending_request](), 'completion must not cancel an active response')
reply({ role = 'assistant', content = 'Finished working on something else' })
assert(#requests == pending_request + 1 and immediate.notification == 'sent', 'deliver at the response boundary')
local resumed = requests[#requests]
assert(resumed[#resumed].role == 'user' and resumed[#resumed].content:find('immediate', 1, true))
assert(resumed[#resumed - 1].content == 'Finished working on something else', 'preserve the full response')
reply({ role = 'assistant', content = 'Results received' })
vim.wait(300, function() return false end)
assert(selections == 1, 'round-boundary completion is only delivered once')
plugin.new()

plugin.send('Keep working while another task runs')
reply({ role = 'assistant', tool_calls = { {
  id = 'batch-background', type = 'function', ['function'] = {
    name = 'start_background_task', arguments = vim.json.encode({
      argv = { 'sh', '-c', 'sleep 0.2; printf batch-result' },
      title = 'Batch interrupt', notify_on_completion = true,
    }),
  },
} } })
approve()
local batch_task = tasks.list()[3]
reply({ role = 'assistant', tool_calls = { {
  id = 'held-command', type = 'function', ['function'] = {
    name = 'run_command', arguments = vim.json.encode({ argv = { 'true' } }),
  },
} } })
local batch_request = #requests
assert(vim.wait(3000, function() return batch_task.status == 'completed' end))
assert(batch_task.notification == 'pending' and #requests == batch_request)
assert(active[batch_request](), 'completion must not invalidate a running tool batch')
assert(selections == 1, 'completion during a tool batch must not ask for approval')
approve()
assert(vim.wait(3000, function() return batch_task.notification == 'sent' end))
assert(#requests == batch_request + 1)
local balanced = requests[#requests]
assert(balanced[#balanced - 1].role == 'tool'
  and balanced[#balanced - 1].tool_call_id == 'held-command'
  and balanced[#balanced - 1].content:find('[exit code: 0]', 1, true),
  'complete the tool normally before delivering background results')
reply({ role = 'assistant', content = 'Batch results received' })
plugin.new()

local origin = { workspace = require('codeit.chat.storage').workspace(), chat_id = 'test' }
local idle, delivered = false, {}
tasks.configure(function(t) return idle and t.origin == origin end,
  function(t, output) delivered[#delivered + 1] = { t, output } end)
local notify = tasks.start({ argv = { 'printf', 'results' }, title = 'Notify', notify_on_completion = true }, origin.workspace, origin)
assert(vim.wait(2000, function() return notify.status == 'completed' end))
assert(selections == 1)
idle = true
assert(vim.wait(1000, function() return selections == 2 end))
choices[2]('Send results to assistant')
assert(#delivered == 0, 'approval does not inject immediately')
assert(vim.wait(1000, function() return #delivered == 1 end))
assert(delivered[1][2]:find('results', 1, true))
vim.wait(300, function() return false end)
assert(#delivered == 1, 'only deliver once')
local decline = tasks.start({ argv = { 'true' }, title = 'Decline', notify_on_completion = true }, origin.workspace, origin)
assert(vim.wait(2000, function() return selections == 3 end))
choices[3](nil)
vim.wait(300, function() return false end)
assert(decline.notification == 'declined' and #delivered == 1)

local quiet = tasks.start({ argv = { 'sh', '-c', "printf '%030000d' 0" }, title = 'Bounded' }, origin.workspace, origin)
assert(vim.wait(3000, function() return quiet.status == 'completed' end))
assert(#quiet.log == 20000 and quiet.truncated and selections == 3)
local failed = tasks.start({ argv = { 'sh', '-c', 'echo failure >&2; exit 7' }, title = 'Failure' }, origin.workspace, origin)
assert(vim.wait(2000, function() return failed.status == 'failed' end))
assert(failed.result.code == 7 and failed.log:find('failure', 1, true))
local timed = tasks.start({ argv = { 'sleep', '5' }, title = 'Timeout', timeout_ms = 50 }, origin.workspace, origin)
assert(vim.wait(2500, function() return timed.status == 'timed out' end))
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
local cancelled = tasks.start({ argv = { 'sh', '-c', 'sleep 0.8; touch "$1"', 'sh', dir .. '/survived' }, title = 'Cancel' }, origin.workspace, origin)
tasks.show()
local view = vim.api.nvim_get_current_buf()
local lines = table.concat(vim.api.nvim_buf_get_lines(view, 0, -1, false), '\n')
assert(lines:find('Slow task', 1, true))
local function press(key)
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(view, 'n')) do
    if mapping.lhs == key then mapping.callback(); return end
  end
  error('missing task-view mapping ' .. key)
end
vim.api.nvim_win_set_cursor(0, { 3, 0 })
press('<CR>')
assert(table.concat(vim.api.nvim_buf_get_lines(view, 0, -1, false), '\n'):find('livedone', 1, true))
press('<CR>')
vim.api.nvim_win_set_cursor(0, { #tasks.list(origin.workspace) + 2, 0 })
press('c')
assert(vim.wait(2500, function() return cancelled.status == 'cancelled' end))
assert(not tasks.cancel(cancelled.id))
vim.wait(1000, function() return false end)
assert(vim.fn.filereadable(dir .. '/survived') == 0)
vim.api.nvim_win_close(0, true)
tasks.shutdown()
vim.fn.delete(dir, 'rf')
print('codeit background task tests passed')
