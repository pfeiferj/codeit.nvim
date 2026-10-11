vim.opt.runtimepath:prepend(vim.fn.getcwd())
local defer, hrtime, on_key, get_mode, notify = vim.defer_fn, vim.uv.hrtime, vim.on_key, vim.api.nvim_get_mode, vim.notify
local notifications = {}
vim.notify = function(message, level, opts)
  notifications[#notifications + 1] = { message = message, level = level, opts = opts }
end
local now, timers, input = 0, {}, nil
local mode, blocking = 'n', false
vim.uv.hrtime = function() return now * 1e6 end
vim.defer_fn = function(callback, delay) timers[#timers + 1] = { at = now + delay, callback = callback } end
vim.on_key = function(callback, ns)
  if ns == vim.api.nvim_create_namespace('codeit_approval_idle') then input = callback; return ns end
  return on_key(callback, ns)
end
vim.api.nvim_get_mode = function() return { mode = mode, blocking = blocking } end
local queue = require('codeit.ui.approval_queue')
vim.on_key = on_key
local managed = require('codeit.ui.managed_tab')
local other_tab = vim.api.nvim_get_current_tabpage()
managed.open()
local codeit_tab = managed.tab()
local function advance(ms)
  local target = now + ms
  while true do
    table.sort(timers, function(a, b) return a.at < b.at end)
    if not timers[1] or timers[1].at > target then break end
    local timer = table.remove(timers, 1)
    now = timer.at
    timer.callback()
  end
  now = target
end
local shown = 0
local function show() shown = shown + 1 end
queue.enqueue(show)
assert(shown == 1, 'idle normal-mode requests should not needlessly wait')
input('j', '')
queue.enqueue(show)
assert(shown == 2, 'generated renderer keys must not reset user idle time')
assert(#notifications == 0, 'immediate approvals should not send delay notifications')
input('j', 'j')
queue.enqueue(show)
assert(#notifications == 1, 'delayed approvals should notify immediately')
assert(notifications[1].message == 'Approval required' and notifications[1].level == vim.log.levels.INFO
  and notifications[1].opts.title == 'Codeit', 'delay notifications should identify the required approval')
advance(750)
assert(shown == 2, 'navigation should postpone approvals')
input('k', 'k')
advance(750)
assert(shown == 2, 'continued navigation must extend the idle delay')
advance(250)
assert(shown == 3, 'approvals should appear after one second without input')
assert(#notifications == 1, 'polling and continued input must not repeat the notification')

for _, held_mode in ipairs({ 'i', 'v', 'c', 'no' }) do
  mode = held_mode
  local notified = #notifications
  queue.enqueue(show)
  assert(#notifications == notified + 1, 'mode delays should notify')
  local before = shown
  advance(2000)
  assert(shown == before, 'approvals must not interrupt mode ' .. held_mode)
  mode = 'n'
  advance(250)
  assert(shown == before + 1)
end
blocking = true
queue.enqueue(show)
local before = shown
advance(1000)
assert(shown == before, 'blocking input must not be interrupted')
blocking = false
advance(250)
assert(shown == before + 1)

vim.api.nvim_set_current_tabpage(other_tab)
local notified = #notifications
queue.enqueue(show, function()
  assert(vim.api.nvim_get_current_tabpage() == codeit_tab, 'workspace-sensitive active checks must wait for the owning tab')
  return true
end)
assert(#notifications == notified + 1, 'approvals delayed in another tab should notify')
before = shown
advance(3000)
assert(shown == before and vim.api.nvim_get_current_tabpage() == other_tab,
  'approval requests must not steal focus from another tab')
vim.api.nvim_set_current_tabpage(codeit_tab)
advance(250)
assert(shown == before + 1, 'returning to Codeit should release pending approvals')

local function check_popup(open)
  local win = open()
  assert(win and vim.api.nvim_win_get_config(win).relative ~= '')
  local current = vim.api.nvim_get_current_win()
  local count, notified = shown, #notifications
  queue.enqueue(show)
  advance(2000)
  assert(#notifications == notified + 1, 'popup delays should notify only once')
  assert(shown == count and vim.api.nvim_get_current_win() == current, 'feature popups must not be covered by approvals')
  vim.api.nvim_win_close(win, true)
  vim.wait(10)
  advance(250)
  assert(shown == count + 1, 'closing the feature popup should release the approval')
end
vim.api.nvim_buf_set_lines(0, 0, -1, false, { '| A | B |', '| --- | --- |', '| one | two |' })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
check_popup(function() return require('codeit.ui.table_popup').show() end)
check_popup(function() return require('codeit.cost_review').show({ provider = 'openrouter', model = 'test' }, vim.fn.getcwd()) end)
check_popup(function() require('codeit.tools.execution.tasks').show(); return vim.api.nvim_get_current_win() end)

local ui = require('codeit.ui')
ui.open(function() end, ui.close)
ui.toggle_popup()
before = shown
queue.enqueue(show)
assert(shown == before + 1, 'the main interactive chat popup should remain eligible for approvals')
ui.toggle_popup()
ui.close()
managed.open()

local cancelled, live = 0, true
mode = 'i'
queue.enqueue(function() cancelled = cancelled + 1 end, function() return live end)
live = false
advance(250)
mode = 'n'
advance(2000)
assert(cancelled == 0, 'stopped requests must never create a delayed prompt')
local order, first_win = {}, nil
queue.enqueue(function()
  order[#order + 1] = 1
  first_win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true,
    { relative = 'editor', row = 1, col = 1, width = 10, height = 2 })
end)
notified = #notifications
queue.enqueue(function() order[#order + 1] = 2 end)
advance(1000)
assert(#notifications == notified + 1, 'approvals waiting behind another prompt should notify only once')
assert(vim.deep_equal(order, { 1 }), 'queued approvals must not overlap an existing prompt')
vim.api.nvim_win_close(first_win, true)
advance(250)
assert(vim.deep_equal(order, { 1, 2 }), 'queued approvals should retain FIFO order')
local failure
queue.enqueue(function() error('test prompt error') end, nil, function(err) failure = err end)
assert(failure and failure:find('test prompt error', 1, true), 'display failures must be reported')
queue.enqueue(show)
assert(shown == before + 2, 'a failed display must not jam the queue')

local approval_round = {}
mode = 'i'
notified, before = #notifications, shown
for _ = 1, 5 do queue.enqueue(show, nil, nil, approval_round) end
advance(2000)
assert(#notifications == notified + 1, 'five delayed approvals in one round should notify once')
mode = 'n'
advance(250)
assert(shown == before + 5, 'batching notifications must not drop approvals')
mode = 'i'
queue.enqueue(show, nil, nil, approval_round)
advance(1000)
assert(#notifications == notified + 1, 'a later approval in the same round must stay quiet after the queue drains')
queue.enqueue(show, nil, nil, {})
assert(#notifications == notified + 2, 'a new tool round should notify independently')
mode = 'n'
advance(250)
approval_round = {}

-- The dispatcher must use current assessments when a deferred approval finally opens.
local approval = require('codeit.tools.approval')
local prompt = require('codeit.tools.approval.prompt')
local write = require('codeit.tools.approval.write')
local original_show, original_write = prompt.show, write.show
local assessment, choose, actions, result = nil, nil, 0, nil
local displayed, displayed_config, diff_seen
prompt.show = function(text, _, callback, config)
  displayed, displayed_config, choose = text, config, callback
end
write.show = function(diff, _, callback) diff_seen, choose = diff, callback end
approval.setup({ validators = { function(_, args)
  if args.argv and args.argv[1] == 'automatic' then return 'approve' end
end } })
mode = 'i'
approval.request('run_command', { argv = { 'echo', 'queued' } }, 'command', function() return true end,
  function(value) result = value end, function() actions = actions + 1 end,
  { review = function() end, assessment = function(listener) assessment = listener end, approval_round = approval_round })
notified = #notifications
assert(not displayed and assessment, 'assessments may run while the prompt is queued')
assessment('Ready assessment', 1)
advance(2000)
assert(not displayed and actions == 0)
mode = 'n'
advance(250)
assert(displayed:find('Ready assessment', 1, true) and displayed_config.safety_score == 1,
  'the opened prompt must show the latest assessment')
assert(actions == 0, 'deferred display must never imply approval')
choose('once')
assert(actions == 1 and not result)
mode = 'i'
approval.request('run_command', { argv = { 'automatic' } }, 'automatic', nil,
  function(value) result = value end, function() actions = actions + 1 end)
assert(actions == 2, 'explicit policy approvals should not be delayed by UI scheduling')
local diff = { before = 'old\n', after = 'new\n', path = 'example.lua' }
approval.request('edit_file', { path = 'example.lua' }, 'edit', function() return true end,
  function(value) result = value end, function() actions = actions + 1 end, { diff = diff, approval_round = approval_round })
assert(#notifications == notified, 'the dispatcher should share notification state across approvals in a round')
advance(2000)
assert(not diff_seen and actions == 2, 'write approvals must also wait')
mode = 'n'
advance(250)
assert(diff_seen == diff, 'deferred write approvals must retain their diff')
choose('once')
assert(actions == 3)
mode, live, displayed = 'i', true, nil
approval.request('read_file', { path = 'cancelled.txt' }, 'read', function() return live end,
  function(value) result = value end, function() actions = actions + 1 end)
live = false
advance(250)
mode = 'n'
advance(2000)
assert(not displayed and actions == 3, 'cancelled dispatch requests must not display or execute')
-- Additional-round decisions must use the same scheduling as individual approvals.
local limit_prompt = require('codeit.tools.limit_prompt')
local decisions, additional = 0, nil
local function request_rounds()
  displayed, choose = nil, nil
  limit_prompt.show(12, function() return live end, function(value)
    decisions, additional = decisions + 1, value
  end)
end
live = true
request_rounds()
assert(displayed:find('Tool limit reached', 1, true), 'idle round approvals should open immediately')
choose('continue')
assert(decisions == 1 and additional == 12)

input('j', 'j')
notified = #notifications
request_rounds()
advance(750)
assert(not displayed and decisions == 1, 'round approvals must wait for idle input')
input('k', 'k')
advance(750)
assert(not displayed, 'continued input must extend the round approval delay')
advance(250)
assert(displayed and #notifications == notified + 1)
choose('stop')
assert(decisions == 2 and additional == nil)

for _, held_mode in ipairs({ 'i', 'v', 'c', 'no' }) do
  local count = decisions
  mode = held_mode
  request_rounds()
  advance(2000)
  assert(not displayed and decisions == count, 'round approvals must not interrupt mode ' .. held_mode)
  mode = 'n'
  advance(250)
  assert(displayed, 'returning to normal mode should release the round approval')
  choose('stop')
  assert(decisions == count + 1 and additional == nil)
end

vim.api.nvim_set_current_tabpage(other_tab)
request_rounds()
advance(2000)
assert(not displayed and vim.api.nvim_get_current_tabpage() == other_tab,
  'round approvals must not steal focus from another tab')
vim.api.nvim_set_current_tabpage(codeit_tab)
advance(250)
assert(displayed)
choose('stop')

local popup = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true,
  { relative = 'editor', row = 1, col = 1, width = 10, height = 2 })
request_rounds()
advance(2000)
assert(not displayed, 'round approvals must wait for other popups to close')
vim.api.nvim_win_close(popup, true)
advance(250)
assert(displayed)
choose('stop')

mode = 'i'
request_rounds()
local before_decisions = decisions
live = false
advance(2000)
mode = 'n'
advance(250)
assert(not displayed and decisions == before_decisions, 'cancelled round approvals must not open or decide')
live = true
prompt.show = function() error('test round prompt error') end
request_rounds()
assert(decisions == before_decisions + 1 and additional == nil, 'display failures must safely decline extra rounds')
prompt.show, write.show = original_show, original_write
vim.defer_fn, vim.uv.hrtime, vim.api.nvim_get_mode, vim.notify = defer, hrtime, get_mode, notify
print('codeit approval queue tests passed')
