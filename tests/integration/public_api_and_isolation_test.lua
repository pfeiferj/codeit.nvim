vim.opt.runtimepath:prepend(vim.fn.getcwd())

local api = require('codeit')
local names = {}
for name, value in pairs(api) do
  assert(type(value) == 'function', 'unexpected public entry: ' .. name)
  names[#names + 1] = name
end
table.sort(names)
local expected = { 'close', 'compact', 'configure', 'context', 'context_files', 'context_full',
  'context_stats', 'costs', 'get_settings', 'history', 'invoke_skill', 'new', 'open', 'resume',
  'send', 'set_provider', 'settings', 'setup', 'stop', 'system_prompt', 'toggle' }
assert(vim.deep_equal(names, expected), 'controller extraction changed the public API')

local defaults = require('codeit.settings.defaults')
local state = require('codeit.chat.state')
local first_state, second_state = state.new(defaults), state.new(defaults)
first_state.config.models.openrouter = 'first-only'
first_state.base_settings.models.copilot = 'first-only'
first_state.messages[1] = { role = 'user', content = 'first-only' }
first_state.selected_skills[1] = { name = 'first-only' }
first_state.context_stats.compactions[1] = { cost = 1 }
assert(second_state.config.models.openrouter == defaults.models.openrouter)
assert(second_state.base_settings.models.copilot == defaults.models.copilot)
assert(#second_state.messages == 0 and #second_state.selected_skills == 0)
assert(#second_state.context_stats.compactions == 0)
assert(defaults.models.openrouter ~= 'first-only' and defaults.models.copilot ~= 'first-only')

local ui = require('codeit.ui')
local first = ui.new({ floating = true, name = 'codeit://layout-first', slash_commands = false })
local second = ui.new({ floating = true, name = 'codeit://layout-second', slash_commands = false })
first.render({ { role = 'user', content = 'first transcript' } }, 'ready', 'test', 'first')
second.render({ { role = 'user', content = 'second transcript' } }, 'ready', 'test', 'second')
local first_win, first_buf = first.open(function() end, first.close)
local second_win, second_buf = second.open(function() end, second.close)
assert(first_win ~= second_win and first_buf ~= second_buf)
vim.api.nvim_buf_set_lines(first_buf, -2, -1, false, { 'first draft' })
vim.api.nvim_buf_set_lines(second_buf, -2, -1, false, { 'second draft' })
first.render({ { role = 'user', content = 'first updated' } }, 'busy', 'test', 'first', nil, nil, false)
assert(first.peek_input() == 'first draft' and second.peek_input() == 'second draft')
assert(table.concat(first.chat_lines(), '\n'):find('first updated', 1, true))
assert(not table.concat(second.chat_lines(), '\n'):find('first updated', 1, true))
first.destroy()
assert(second.is_open() and vim.api.nvim_win_is_valid(second_win))
second.render({ { role = 'user', content = 'second updated' } }, 'ready', 'test', 'second')
assert(second.peek_input() == 'second draft')
second.destroy()

print('codeit module layout and instance isolation tests passed')
