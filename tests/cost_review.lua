vim.opt.runtimepath:prepend(vim.fn.getcwd())
local temp = vim.fn.tempname()
vim.fn.mkdir(temp, 'p')
local original_stdpath = vim.fn.stdpath
vim.fn.stdpath = function(kind) return kind == 'data' and temp or original_stdpath(kind) end
local history = require('codeit.history')
local costs = require('codeit.cost_tools')
local workspace, other = '/test/project', '/test/other'
local function stamp(day) return os.time({ year = 2026, month = 6, day = day, hour = 12 }) end
local function save(ws, id, day, amount, missing)
  assert(history.save(ws, id, { provider = 'openrouter', model = 'test-model', updated_at = stamp(day),
    cost = amount, missing_cost = missing, tokens_in = 100, tokens_out = 10,
    messages = { { role = 'user', content = 'Investigate expensive tests' },
      { role = 'assistant', content = 'Read the logs',
        _copilot_reasoning = { { summary = { { text = 'private-secret' } } } },
        tool_calls = { { id = 'read', ['function'] = { name = 'read_file', arguments = '{"path":"logs"}' } } } },
      { role = 'tool', tool_call_id = 'read', content = string.rep('log output\n', 250) },
      { role = 'assistant', content = 'Done' } } }))
end
save(workspace, 'one', 1, 1.25, 0)
save(workspace, 'two', 2, 0, 1)
save(other, 'three', 2, 2.5, 0)
local bad = temp .. '/codeit/chats/' .. vim.fn.sha256(workspace) .. '/bad.json'
vim.fn.writefile({ '{broken' }, bad)
assert(#history.list_all() == 3, 'all-workspace discovery skips corrupt files')
local tools = costs.new(history.list_all())
local function execute(name, args)
  return vim.json.decode(tools.execute(name, args or {}))
end
local result = execute('get_costs')
assert(result.totals.chats == 3 and result.totals.cost == 3.75 and result.totals.missing_cost == 1)
assert(result.totals.tokens_in == 300 and #result.groups == 2)
assert(result.groups[1].day == '2026-06-02' and result.groups[1].chats == 2)
result = execute('get_costs', { group_by = 'workspace', workspace = workspace })
assert(#result.groups == 1 and result.totals.cost == 1.25)
result = execute('get_costs', { group_by = 'day_workspace' })
assert(#result.groups == 3)
result = execute('list_cost_chats', { from_day = '2026-06-02', to_day = '2026-06-02', workspace = workspace })
assert(#result.chats == 1 and result.chats[1].chat_id == 'two')
result = execute('read_cost_chat', { workspace = workspace, chat_id = 'one' })
assert(result.truncated and #result.lines == 200)
assert(not table.concat(result.lines, '\n'):find('private-secret', 1, true))
result = execute('search_cost_chat', { workspace = workspace, chat_id = 'one', query = 'expensive' })
assert(#result.matches == 1)
for _, args in ipairs({ { offset = -1 }, { offset = 0.5 }, { offset = math.huge },
  { group_by = 'model' }, { from_day = '2026-02-30' }, { from_day = 'no' },
  { from_day = '2026-06-02', to_day = '2026-06-01' }, { unexpected = true } }) do
  assert(tools.execute('get_costs', args):match('^Error:'))
end
assert(tools.execute('read_cost_chat', { workspace = workspace, chat_id = '../../secret' }):match('^Error:'))
assert(tools.execute('read_cost_chat', {}):match('^Error:'))
assert(tools.execute('run_command', {}):match('^Error:'))
assert(tools.execute('get_costs', vim.NIL):match('^Error:'))
local many = {}
for i = 1, 120 do
  many[i] = { workspace = '/project/' .. i, id = tostring(i), updated_at = stamp(1),
    messages = {}, summary = string.rep('λ', 1000), cost = 0 }
end
local paged = costs.new(many)
local first = vim.json.decode(paged.execute('list_cost_chats', {}))
assert(first.truncated and first.next_offset == #first.chats)
assert(#paged.execute('list_cost_chats', {}) < 20000)
local second = vim.json.decode(paged.execute('list_cost_chats', { offset = first.next_offset }))
assert(second.chats[1].chat_id ~= first.chats[#first.chats].chat_id)
local unknown = costs.new({ { workspace = workspace, id = 'old', messages = {}, updated_at = stamp(1) } })
result = vim.json.decode(unknown.execute('get_costs', {}))
assert(result.totals.missing_cost == 1 and result.totals.missing_in)

local requests, pending = {}, nil
package.loaded['codeit.providers'] = { chat = function(config, messages, specs, callback)
  requests[#requests + 1] = { config = config, messages = vim.deepcopy(messages), specs = specs }
  pending = callback
end }
local plugin = require('codeit')
plugin.setup({ feature_settings = { cost_review = { model = 'cost-model' } } })
assert(vim.fn.exists(':CodeitCosts') == 2)
local win, buf = plugin.costs()
local function text() return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') end
local function key(lhs)
  local mapping = vim.api.nvim_buf_call(buf, function() return vim.fn.maparg(lhs, 'n', false, true) end)
  assert(mapping.callback, 'missing key: ' .. lhs)
  mapping.callback()
end
assert(text():find('Saved total: $3.750000+', 1, true) and #requests == 0)
key('w')
assert(text():find(workspace, 1, true) and text():find(other, 1, true))
key('s')
assert(text():find('No saved chats in this scope.', 1, true))
key('s')
assert(text():find('Saved total: $3.750000+', 1, true))
local function ask(question)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  -- The draft is the final editable line in the shared chat UI.
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, #lines - 1, -1, false, { question })
  vim.api.nvim_win_set_cursor(win, { #lines, 0 })
  key('<CR>')
end
ask('Why so expensive?')
assert(#requests == 1 and requests[1].config.model == 'cost-model' and #requests[1].specs == 4)
pending({ role = 'assistant', tool_calls = { { id = 'costs', type = 'function',
  ['function'] = { name = 'get_costs', arguments = '{"group_by":"workspace"}' } } } }, nil,
  { cost = 0.05, prompt_tokens = 20, completion_tokens = 5 })
assert(#requests == 2 and requests[2].messages[#requests[2].messages].role == 'tool')
pending({ role = 'assistant', content = 'One chat accounted for $2.50.' }, nil,
  { cost = 0.1, prompt_tokens = 30, completion_tokens = 10 })
assert(text():find('One chat accounted', 1, true) and text():find('This review: $0.150000', 1, true))
local saved = history.list(history.workspace())
assert(#saved == 1 and saved[1].kind == 'cost_review' and math.abs(saved[1].cost - 0.15) < 0.000001)
ask('More details')
pending(nil, 'offline')
assert(text():find('Error: offline', 1, true))
ask('Retry')
key('q')
assert(not vim.api.nvim_win_is_valid(win))
local before = #requests
pending({ role = 'assistant', content = 'Late response' }, nil, { cost = 0.2 })
assert(#requests == before, 'closing stops further model/tool rounds')
saved = history.list(history.workspace())
assert(math.abs(saved[1].cost - 0.35) < 0.000001 and saved[1].missing_in)
vim.wait(20)
local empty_win = plugin.costs()
assert(vim.api.nvim_win_is_valid(empty_win))
vim.api.nvim_win_close(empty_win, true)
vim.wait(20)
save(history.workspace(), 'active', 1, 0, 0)
assert(plugin.resume('active'))
local review_win = plugin.costs()
assert(history.load(history.workspace(), 'active').updated_at == stamp(1),
  'opening cost review must not change the active chat date')
vim.api.nvim_win_close(review_win, true)
vim.wait(20)
plugin.close()
vim.fn.stdpath = original_stdpath
vim.fn.delete(temp, 'rf')
print('codeit cost review tests passed')
