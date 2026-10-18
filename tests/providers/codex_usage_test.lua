vim.opt.runtimepath:prepend(vim.fn.getcwd())
local quota = require('codeit.providers.codex.usage')
local format = require('codeit.usage_format')
local breakdown = require('codeit.cost_breakdown')
local future = os.time() + 3600
local headers = 'HTTP/2 200\r\nX-Codex-Primary-Used-Percent: 12.5\r\n'
  .. 'x-codex-primary-window-minutes: 300\r\nx-codex-primary-reset-at: ' .. future .. '\r\n'
  .. 'x-codex-secondary-used-percent: 40\r\nx-codex-secondary-window-minutes: 10080'
local snapshot = quota.parse(headers)
assert(snapshot.primary.used_percent == 12.5 and snapshot.primary.reset_at == future)
assert(format.subscription(snapshot) == 'Codex: 5h 12.5% used · 7d 40% used')
assert(format.subscription(nil) == 'Codex: usage unknown')
assert(quota.parse('') == nil)
for _, invalid in ipairs({ '-1', '101', 'nan', 'inf', 'bad' }) do
  assert(quota.parse('x-codex-primary-used-percent: ' .. invalid) == nil)
end
local event = { type = 'codex.rate_limits', rate_limits = {
  primary = { used_percent = 0, window_minutes = 300 },
} }
local update = quota.parse(headers, event)
assert(update.primary.used_percent == 0 and update.secondary.used_percent == 40)
event.metered_limit_name = 'codex_other'
assert(quota.parse(headers, event).primary.used_percent == 12.5, 'do not mix model-specific quota pools')
assert(quota.parse('', event) == nil)
assert(quota.parse('', { rate_limits = vim.NIL }) == nil)
local expired = quota.parse('x-codex-primary-used-percent: 100\nx-codex-primary-reset-at: 1')
assert(format.subscription(expired) == 'Codex: primary unknown', 'expired snapshots are not current usage')

local ui = require('codeit.ui')
local original_render, billing = ui.render
ui.render = function(_, _, _, _, value) billing = value end
local session = require('codeit.chat.state').new({ provider = 'codex', models = { codex = 'test' } })
local helpers = { model = function() return 'test' end, save = function() end }
require('codeit.chat.usage').attach({}, session, helpers)
helpers.render()
assert(billing:find('Codex: usage unknown', 1, true) and not billing:find('$', 1, true))
local turn = { cost = 0, missing_cost = 0, cost_by_function = {} }
helpers.record_usage({ prompt_tokens = 100, completion_tokens = 10, codex_subscription = snapshot }, 'main_chat', 'codex', turn)
assert(session.cost == 0 and session.missing_cost == 0 and session.tokens_in == 100)
assert(billing:find('Codex: 5h 12.5% used · 7d 40% used | In:', 1, true))
assert(format.turn_cost(turn) == 'Subscription')
helpers.record_usage({ cost = 0.125, prompt_tokens = 20, completion_tokens = 3 }, 'tool_review', 'openrouter', turn)
assert(session.cost == 0.125 and session.missing_cost == 0)
assert(billing:find('Codex: 5h 12.5% used · 7d 40% used ($0.125)', 1, true))
assert(format.turn_cost(turn) == 'Subscription ($0.125)')
helpers.record_usage(nil, 'compaction', 'openai', turn)
assert(session.missing_cost == 1 and turn.missing_cost == 1)
assert(billing:find('($0.125+)', 1, true), 'unknown dollar usage still marks the dollar subtotal incomplete')
helpers.record_usage({ prompt_tokens = 5, completion_tokens = 1 }, 'context_review', 'codex', turn)
assert(session.missing_cost == 1, 'Codex secondary requests do not add missing-dollar reports')
assert(format.turn_cost(turn) == 'Subscription ($0.125+)')
assert(vim.deep_equal(breakdown.restore(session.cost_by_function), session.cost_by_function))
local merged = {}
breakdown.merge(merged, session.cost_by_function)
local count, dollars = breakdown.subscription_requests(merged)
assert(count == 2 and dollars)
assert(merged.main_chat.subscription_requests == 1)
ui.render = original_render

local temp, original_stdpath = vim.fn.tempname(), vim.fn.stdpath
vim.fn.stdpath = function(kind) return kind == 'data' and temp or original_stdpath(kind) end
local history = require('codeit.chat.storage')
local workspace, id = '/test/codex-usage', history.new_id()
assert(history.save(workspace, id, { provider = 'codex', model = 'test', cost = session.cost,
  missing_cost = session.missing_cost, cost_by_function = session.cost_by_function,
  tokens_in = session.tokens_in, tokens_out = session.tokens_out,
  messages = { { role = 'user', content = 'hello' }, { role = 'assistant', content = 'hi' } },
  turn_costs = { vim.tbl_extend('force', turn, { first = 1 }) }, updated_at = os.time() }))
local saved = assert(history.load(workspace, id))
assert(saved.turn_costs[1].cost_by_function.main_chat.subscription_requests == 1)
assert(format.turn_cost(saved.turn_costs[1]) == 'Subscription ($0.125+)')
local tools = require('codeit.tools.cost').new({ vim.tbl_extend('force', saved, { workspace = workspace, id = id }) })
local totals = vim.json.decode(tools.execute('get_costs', {})).totals
assert(totals.cost == 0.125 and totals.missing_cost == 1)
assert(totals.cost_by_function.main_chat.subscription_requests == 1)
assert(breakdown.subscription_requests(totals.cost_by_function) == 2)
vim.fn.stdpath = original_stdpath
vim.fn.delete(temp, 'rf')
vim.cmd('qa!')
