vim.opt.runtimepath:prepend(vim.fn.getcwd())
local temp = vim.fn.tempname()
vim.fn.mkdir(temp, 'p')
local stdpath = vim.fn.stdpath
vim.fn.stdpath = function(kind) return kind == 'data' and temp or stdpath(kind) end
local history = require('codeit.chat.storage')
local workspace = history.workspace()
local function save(ws, id, records)
  assert(history.save(ws, id, { provider = 'openrouter', model = 'test', messages = {}, auto_approvals = records }))
end
local records = {}
for i = 1, 60 do
  records[i] = { name = 'run_command', args = { argv = { 'inspect', 'topic-' .. i } }, timestamp = i, reason = 'validator' }
end
records[#records + 1] = { name = 'read_file', args = { path = 'sample.lua' }, timestamp = 61, reason = 'trusted_read_or_window' }
save(workspace, 'one', records)
save('/other-project', 'two', { { name = 'other_tool', args = {}, timestamp = 1, reason = 'validator' } })
local requests, pending = {}, nil
package.loaded['codeit.providers'] = { chat = function(config, messages, specs, callback)
  requests[#requests + 1] = { config = config, messages = vim.deepcopy(messages), specs = specs }
  pending = callback
end }
local plugin = require('codeit')
plugin.setup({ feature_settings = { tool_review = { model = 'audit-reviewer' } } })
assert(vim.fn.exists(':CodeitAutoApprovals') == 2)
assert(require('codeit.commands.slash').parse('/autoApprovals').command == 'CodeitAutoApprovals')
local win, buf = plugin.auto_approvals()
local function text() return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') end
local function key(lhs)
  local mapping = vim.api.nvim_buf_call(buf, function() return vim.fn.maparg(lhs, 'n', false, true) end)
  assert(mapping.callback, 'missing key: ' .. lhs)
  mapping.callback()
end
local function select_row(needle)
  for line, value in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if value:find(needle, 1, true) then vim.api.nvim_win_set_cursor(win, { line, 0 }); key('<CR>'); return end
  end
  error('row missing: ' .. needle)
end
assert(#requests == 0, 'opening the view must not call AI')
assert(text():find('61 recorded approvals', 1, true))
assert(not text():find('other_tool', 1, true), 'default scope is current workspace only')
select_row('run_command / inspect')
assert(text():find('60 recorded approvals', 1, true) and text():find('Entries 1–50 of 60', 1, true))
key('n')
assert(text():find('Entries 51–60 of 60', 1, true))
key('p')
assert(text():find('Entries 1–50 of 60', 1, true))
select_row('topic-60')
assert(text():find('## Approval #', 1, true) and text():find('tool_call', 1, true) == nil)
assert(text():find('topic-60', 1, true))
key('b')
assert(text():find('Entries 1–50 of 60', 1, true))
key('b')
assert(text():find('By tool', 1, true))
local all_calls = 0
local list_all = history.list_all
history.list_all = function() all_calls = all_calls + 1; return list_all() end
vim.ui.input = function(_, cb) cb('') end
key('w')
assert(all_calls == 1 and text():find('62 recorded approvals', 1, true) and text():find('other_tool', 1, true))
vim.ui.input = function(_, cb) cb(workspace) end
key('w')
assert(all_calls == 1 and not text():find('other_tool', 1, true))
local function question(value)
  vim.api.nvim_buf_set_lines(buf, -2, -1, false, { value })
  vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
  key('<CR>')
end
question('Which commands were approved?')
assert(#requests == 1 and requests[1].config.model == 'audit-reviewer')
assert(requests[1].messages[#requests[1].messages].content:find(workspace, 1, true))
assert(requests[1].specs[1]['function'].name == 'get_auto_approval_stats')
pending({ role = 'assistant', tool_calls = { { id = 'stats', ['function'] = { name = 'get_auto_approval_stats', arguments = '{}' } } } }, nil,
  { cost = 0.01, prompt_tokens = 100, completion_tokens = 10 })
assert(#requests == 2)
local tool_result = requests[2].messages[#requests[2].messages]
assert(tool_result.role == 'tool' and vim.json.decode(tool_result.content).total_approvals == 61)
pending({ role = 'assistant', content = '60 inspect invocations were automatically approved.' }, nil,
  { cost = 0.02, prompt_tokens = 120, completion_tokens = 20 })
assert(text():find('60 inspect invocations', 1, true) and text():find('$0.030', 1, true))
local review
for _, chat in ipairs(history.list(workspace)) do if chat.kind == 'auto_approval_review' then review = chat end end
assert(review and review.cost == 0.03 and review.cost_by_function.tool_review.requests == 2)
assert(review.auto_approvals == nil, 'reviewer reads must not generate main-chat approvals')
-- Failure does not leave unmatched tool calls in subsequent requests.
question('More details?')
pending(nil, 'offline')
assert(text():find('Error: offline', 1, true))
question('Try again')
assert(requests[#requests].messages[#requests[#requests].messages].role == 'user')
key('q')
assert(not vim.api.nvim_win_is_valid(win))
local before = #requests
pending({ role = 'assistant', content = 'late answer' }, nil, { cost = 0.04 })
assert(#requests == before, 'closed reviewer must not continue')
local total
for _, chat in ipairs(history.list(workspace)) do if chat.kind == 'auto_approval_review' then total = chat.cost end end
assert(total == 0.07, 'in-flight reviewer costs must still be saved after closing')
vim.fn.delete(temp, 'rf')
print('codeit auto-approval review UI tests passed')
