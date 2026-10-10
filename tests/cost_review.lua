vim.opt.runtimepath:prepend(vim.fn.getcwd())
local temp = vim.fn.tempname()
vim.fn.mkdir(temp, 'p')
local original_stdpath = vim.fn.stdpath
vim.fn.stdpath = function(kind) return kind == 'data' and temp or original_stdpath(kind) end
local history = require('codeit.history')
local costs = require('codeit.cost_tools')
local usage_format = require('codeit.usage_format')
local breakdown = require('codeit.cost_breakdown')
local buckets = {}
breakdown.add(buckets, 'main_chat', 0, 20, 0)
breakdown.add(buckets, 'main_chat', nil, nil, 5)
assert(buckets.main_chat.requests == 2 and buckets.main_chat.cost == 0 and buckets.main_chat.missing_cost == 1)
assert(buckets.main_chat.tokens_in == 20 and buckets.main_chat.tokens_out == 5)
assert(buckets.main_chat.missing_in and not buckets.main_chat.missing_out)
assert(vim.deep_equal(breakdown.restore(buckets), buckets))
local legacy_bucket = { cost = 1, requests = 1, missing_cost = 0 }
local restored = breakdown.restore({ main_chat = legacy_bucket }).main_chat
assert(restored.cost == 1 and restored.tokens_in == 0 and restored.tokens_out == 0)
assert(restored.missing_in and restored.missing_out, 'legacy token totals are unknown, not zero')
breakdown.add({ main_chat = restored }, 'main_chat', 0, 10, 2)
assert(restored.tokens_in == 10 and restored.tokens_out == 2 and restored.missing_in and restored.missing_out)
local merged = {}
breakdown.merge(merged, buckets)
breakdown.merge(merged, { main_chat = legacy_bucket })
assert(merged.main_chat.tokens_in == 20 and merged.main_chat.tokens_out == 5)
assert(merged.main_chat.missing_in and merged.main_chat.missing_out)
for _, invalid in ipairs({ -1, math.huge, 0 / 0, 'bad', vim.NIL }) do
  local restored_bad = breakdown.restore({ main_chat = vim.tbl_extend('force', legacy_bucket,
    { tokens_in = invalid, tokens_out = 0 }) }).main_chat
  assert(restored_bad.tokens_in == 0 and restored_bad.missing_in and not restored_bad.missing_out)
end
for _, bad_bucket in ipairs({ { cost = -1, requests = 1, missing_cost = 0 },
  { cost = math.huge, requests = 1, missing_cost = 0 }, { cost = 0 / 0, requests = 1, missing_cost = 0 },
  { cost = 1, requests = 0, missing_cost = 1 }, { cost = 1, requests = 0.5, missing_cost = 0 } }) do
  assert(next(breakdown.restore({ main_chat = bad_bucket })) == nil)
end
assert(next(breakdown.restore(vim.NIL)) == nil)
assert(next(breakdown.restore({ unknown = buckets.main_chat })) == nil)
assert(usage_format.cost(1.2346) == '$1.235')
assert(usage_format.cost(0, true) == '$0.000+')
assert(usage_format.tokens(0) == '0m')
assert(usage_format.tokens(1234567) == '1.235m')
assert(usage_format.tokens(120000) == '0.12m')
assert(usage_format.tokens(12345, 1000, 'k') == '12.345k')
local workspace, other = '/test/project', '/test/other'
local function stamp(day) return os.time({ year = 2026, month = 6, day = day, hour = 12 }) end
local function save(ws, id, day, amount, missing)
  assert(history.save(ws, id, { provider = 'openrouter', model = 'test-model', updated_at = stamp(day),
    cost = amount, missing_cost = missing, tokens_in = 1234567, tokens_out = 120000,
    missing_in = missing > 0, missing_out = missing > 0,
    cost_by_function = id == 'one' and {
      main_chat = { cost = 0.123456, requests = 1, missing_cost = 0,
        tokens_in = 1234567, tokens_out = 120000, missing_in = false, missing_out = false },
      context_review = { cost = 1.126544, requests = 1, missing_cost = 0 } } or nil,
    turn_costs = id == 'one' and { { first = 1, cost = 0.123456, missing_cost = 0,
        cost_by_function = { main_chat = { cost = 0.123456, requests = 1, missing_cost = 0 } } },
      { first = 5, cost = 1.126544, missing_cost = 0,
        cost_by_function = { context_review = { cost = 1.126544, requests = 1, missing_cost = 0 } } } } or nil,
    messages = { { role = 'user', content = 'Investigate expensive tests' },
      { role = 'assistant', content = 'Read the logs',
        _copilot_reasoning = { { summary = { { text = 'private-secret' } } } },
        tool_calls = { { id = 'read', ['function'] = { name = 'read_file', arguments = '{"path":"logs"}' } } } },
      { role = 'tool', tool_call_id = 'read', content = string.rep('log output\n', 250) },
      { role = 'assistant', content = 'Done' },
      { role = 'user', content = 'Explain slow step' },
      { role = 'assistant', content = 'Another answer' } } }))
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
assert(result.totals.tokens_in == 3703701 and #result.groups == 2)
assert(result.totals.cost_by_function.main_chat.cost == 0.123456)
assert(result.totals.cost_by_function.main_chat.tokens_in == 1234567)
assert(result.totals.cost_by_function.main_chat.tokens_out == 120000)
assert(not result.totals.cost_by_function.main_chat.missing_in)
assert(result.totals.cost_by_function.context_review.missing_in)
assert(result.totals.cost_by_function.context_review.cost == 1.126544)
assert(result.totals.unattributed_cost == 2.5 and result.totals.unattributed_missing_cost == 1)
assert(result.groups[2].cost_by_function.context_review.requests == 1)
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
assert(table.concat(result.lines, '\n'):find('0.123456', 1, true), 'tools must retain full cost precision')
result = execute('search_cost_chat', { workspace = workspace, chat_id = 'one', query = 'cost (USD)' })
assert(#result.matches == 2)
local first_turn = vim.json.decode(result.matches[1].text:match('cost %(USD%): (.*)'))
local second_turn = vim.json.decode(result.matches[2].text:match('cost %(USD%): (.*)'))
assert(first_turn.cost == 0.123456 and second_turn.cost == 1.126544)
assert(first_turn.cost_by_function.main_chat.cost == 0.123456)
assert(second_turn.cost_by_function.context_review.cost == 1.126544)
local chat_functions = execute('search_cost_chat', { workspace = workspace, chat_id = 'one', query = 'Chat costs by function' })
assert(#chat_functions.matches == 1 and chat_functions.matches[1].text:find('context_review', 1, true))
local chat_list = execute('list_cost_chats', { workspace = workspace, from_day = '2026-06-01', to_day = '2026-06-01' })
assert(chat_list.chats[1].cost_by_function.main_chat.requests == 1)
assert(result.matches[2].text:find('Turn 2', 1, true))
result = execute('search_cost_chat', { workspace = workspace, chat_id = 'two', query = 'cost (USD)' })
assert(result.matches[1].text:find('unknown (not recorded)', 1, true))
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
assert(result.totals.unattributed_missing_cost == 1 and next(result.totals.cost_by_function) == nil)
local rounding = costs.new({ { workspace = workspace, id = 'rounding', messages = {}, cost = 0.1 + 0.2,
  cost_by_function = { main_chat = { cost = 0.3, requests = 2, missing_cost = 0 } } } })
assert(vim.json.decode(rounding.execute('get_costs', {})).totals.unattributed_cost == 0,
  'floating-point addition residue is not an unattributed charge')

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
assert(text():find('Saved total: $3.750+ · 3 chats · In: 3.704m+ · Out: 0.36m+', 1, true) and #requests == 0)
assert(not text():find(costs.note, 1, true), 'cost overview paragraph must not be displayed')
assert(not text():find('# Cost review', 1, true), 'cost review must not repeat the popup title')
assert(vim.api.nvim_win_get_config(win).title[1][1] == ' Cost review ', 'popup title must remain')
local function assert_table(rows)
  local alignment = { 'left' }
  for column = 2, #rows[1] do alignment[column] = 'right' end
  local expected = require('codeit.table_popup').format({ rows = rows, alignment = alignment })
  assert(text():find(table.concat(expected, '\n'), 1, true), 'cost table must use popup formatting')
  for _, line in ipairs(expected) do
    -- strdisplaywidth includes wrapped-window break indentation for wide tables.
    assert(vim.fn.strwidth(line) == vim.fn.strwidth(expected[1]))
  end
end
assert_table({
  { 'Group', 'Chats', 'USD', 'Input tokens', 'Output tokens' },
  { '2026-06-02', '2', '$2.500+', '2.469m+', '0.24m+' },
  { '2026-06-01', '1', '$1.250', '1.235m', '0.12m' },
})
local cost_ns = vim.api.nvim_get_namespaces().codeit_cost_review
local function assert_highlights()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local marks = vim.api.nvim_buf_get_extmarks(buf, cost_ns, 0, -1, { details = true })
  local groups = {}
  for _, mark in ipairs(marks) do
    local row, col, details = mark[2], mark[3], mark[4]
    assert(row < #lines, 'cost highlights must stay within the rendered header')
    assert(not details.line_hl_group, 'cost table must not have alternating row shading')
    if details.hl_group then
      groups[details.hl_group] = true
      local highlighted = lines[row + 1]:sub(col + 1, details.end_col)
      if details.hl_group == 'CodeitCostAmount' then
        assert(highlighted:find('$', 1, true), 'amount highlighting must align with the USD cell')
      elseif details.hl_group == 'CodeitCostIncomplete' and row > 4 then
        assert(highlighted == '+', 'incomplete markers must be highlighted precisely')
      end

    end
  end
  assert(groups.CodeitTableHeader and groups.CodeitTableBorder and groups.CodeitCostTotal)
  assert(groups.CodeitCostGroup and groups.CodeitCostAmount and groups.CodeitCostIncomplete)
  return #marks
end
assert_highlights()
key('w')
local workspace_marks = assert_highlights()
key('w')
assert(assert_highlights() == workspace_marks, 'rerendering must not accumulate highlights')
assert(text():find(workspace, 1, true) and text():find(other, 1, true))
key('s')
assert(text():find('No saved chats in this scope.', 1, true))
key('s')
assert(text():find('Saved total: $3.750+', 1, true))
assert_highlights()
key('f')
assert(text():find('f: functions', 1, true) and #requests == 0)
assert_table({
  { 'Function', 'Requests', 'USD', 'Input tokens', 'Output tokens', 'Missing cost reports' },
  { 'Unattributed', '—', '$2.500+', '—', '—', '1' },
  { 'context_review', '1', '$1.127', '0m+', '0m+', '0' },
  { 'main_chat', '1', '$0.123', '1.235m', '0.12m', '0' },
})
assert(text():find('Groups 1–3 of 3', 1, true))
local function_marks = assert_highlights()
key('n')
key('p')
assert(assert_highlights() == function_marks, 'function view must stay on its single page')
key('s')
assert(text():find('No saved chats in this scope.', 1, true))
key('s')
key('d')
assert_table({
  { 'Group', 'Chats', 'USD', 'Input tokens', 'Output tokens' },
  { '2026-06-02', '2', '$2.500+', '2.469m+', '0.24m+' },
  { '2026-06-01', '1', '$1.250', '1.235m', '0.12m' },
})
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
assert(text():find('One chat accounted', 1, true) and text():find('This review: $0.150', 1, true))
assert_highlights()
local saved = history.list(history.workspace())
assert(#saved == 1 and saved[1].kind == 'cost_review' and math.abs(saved[1].cost - 0.15) < 0.000001)
assert(#saved[1].turn_costs == 1 and saved[1].turn_costs[1].first == 2)
assert(math.abs(saved[1].turn_costs[1].cost - 0.15) < 0.000001)
assert(saved[1].cost_by_function.cost_review.requests == 2)
assert(math.abs(saved[1].cost_by_function.cost_review.cost - 0.15) < 0.000001)
assert(saved[1].turn_costs[1].cost_by_function.cost_review.requests == 2)
assert(saved[1].cost_by_function.cost_review.tokens_in == 50 and saved[1].cost_by_function.cost_review.tokens_out == 15)
assert(not saved[1].cost_by_function.cost_review.missing_in and not saved[1].cost_by_function.cost_review.missing_out)
assert(saved[1].turn_costs[1].cost_by_function.cost_review.tokens_in == 50)
assert(saved[1].turn_costs[1].cost_by_function.cost_review.tokens_out == 15)
assert(text():find('**You** · Turn cost: $0.150', 1, true))
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
assert(#saved[1].turn_costs == 3 and saved[1].turn_costs[2].first == 6 and saved[1].turn_costs[3].first == 7)
assert(saved[1].turn_costs[3].cost == 0.2, 'late review-session usage must persist on the question that incurred it')
assert(saved[1].cost_by_function.cost_review.requests == 3)
assert(saved[1].turn_costs[3].cost_by_function.cost_review.cost == 0.2)
assert(saved[1].cost_by_function.cost_review.tokens_in == 50 and saved[1].cost_by_function.cost_review.missing_in)
assert(saved[1].cost_by_function.cost_review.tokens_out == 15 and saved[1].cost_by_function.cost_review.missing_out)
assert(saved[1].turn_costs[3].cost_by_function.cost_review.missing_in)
vim.wait(20)
local empty_win = plugin.costs()
assert(vim.api.nvim_win_is_valid(empty_win))
vim.api.nvim_win_close(empty_win, true)
vim.wait(20)
assert(history.save(workspace, 'missing-function', { provider = 'openrouter', model = 'test-model',
  updated_at = stamp(3), cost = 0, missing_cost = 1, tokens_in = 0, tokens_out = 0, messages = {},
  cost_by_function = { context_review = { cost = 0, requests = 2, missing_cost = 1 } } }))
win, buf = require('codeit.cost_review').show({ provider = 'openrouter', model = 'test-model' }, workspace)
key('f')
key('s')
assert_table({
  { 'Function', 'Requests', 'USD', 'Input tokens', 'Output tokens', 'Missing cost reports' },
  { 'context_review', '3', '$1.127+', '0m+', '0m+', '1' },
  { 'main_chat', '1', '$0.123', '1.235m', '0.12m', '0' },
  { 'Unattributed', '—', '$0.000+', '—', '—', '1' },
})
assert_highlights()
assert(text():find('Saved total: $1.250+ · 3 chats', 1, true))
vim.api.nvim_win_close(win, true)
vim.wait(20)
local zero_workspace = '/test/zero'
save(zero_workspace, 'zero', 1, 0, 0)
win, buf = require('codeit.cost_review').show({ provider = 'openrouter', model = 'test-model' }, zero_workspace)
key('f')
key('s')
assert(text():find('No recorded function costs in this scope.', 1, true))
assert(not text():find('No saved chats in this scope.', 1, true))
assert_table({ { 'Function', 'Requests', 'USD', 'Input tokens', 'Output tokens', 'Missing cost reports' } })
vim.api.nvim_win_close(win, true)
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
