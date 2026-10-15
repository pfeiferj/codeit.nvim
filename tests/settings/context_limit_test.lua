vim.opt.runtimepath:prepend(vim.fn.getcwd())
local temp = vim.fn.tempname()
vim.fn.mkdir(temp .. '/one', 'p')
vim.fn.mkdir(temp .. '/two', 'p')
vim.fn.chdir(temp .. '/one')
local detected = 0
package.loaded['codeit.providers'] = {
  context_limit = function(_, callback) detected = detected + 1; callback(128000) end,
  chat = function(_, _, _, callback) callback({ role = 'assistant', content = 'ok' }) end,
}
local plugin = require('codeit')
local settings = require('codeit.settings')
local picker = require('codeit.settings.picker')
vim.fn.delete(vim.fn.stdpath('data') .. '/codeit/settings.json')
plugin.setup({ max_context_tokens = false, context_review = false })
local base = plugin.get_settings()
assert(base.max_context_tokens == false)
local global = vim.deepcopy(base)
global.max_context_tokens = 32000
assert(plugin.configure(global, 'global'))
plugin.setup({ max_context_tokens = false, context_review = false })
assert(plugin.get_settings().max_context_tokens == 32000)
plugin.send('manual limit')
assert(detected == 0, 'a manual limit bypasses provider detection')
local workspace = vim.deepcopy(global)
workspace.max_context_tokens = 'auto'
assert(plugin.configure(workspace, 'workspace'))
plugin.setup({ max_context_tokens = false, context_review = false })
assert(plugin.get_settings().max_context_tokens == 'auto', 'workspace can override a global limit with automatic detection')
plugin.send('automatic limit')
assert(detected == 1, 'automatic settings must restore provider detection at runtime')
local disabled = vim.deepcopy(workspace)
disabled.max_context_tokens = false
assert(plugin.configure(disabled))
plugin.send('disabled limit')
assert(detected == 1, 'disabled settings bypass detection')
local legacy = vim.deepcopy(base)
legacy.max_context_tokens = nil
assert(plugin.configure(legacy))
assert(plugin.get_settings().max_context_tokens == false, 'older callers preserve the current limit')
assert(settings.save(legacy, 'workspace', require('codeit.chat.storage').workspace()))
plugin.setup({ max_context_tokens = false, context_review = false })
assert(plugin.get_settings().max_context_tokens == 32000, 'legacy snapshots inherit the lower-precedence limit')
vim.fn.chdir(temp .. '/two')
assert(plugin.get_settings().max_context_tokens == 32000, 'workspace changes restore the global limit')
for _, bad in ipairs({ 0, -1, math.huge, -math.huge, 0 / 0, true, '32000', {}, 'invalid' }) do
  local values = vim.deepcopy(base)
  values.max_context_tokens = bad
  assert(not settings.validate(values), 'invalid context limits must be rejected')
end

local steps, inputs, applied, scope, input_default
require('codeit.settings.menu').select = function(items, _, callback)
  local wanted = table.remove(steps, 1)
  for _, item in ipairs(items) do
    if item.id == wanted then return callback(item) end
  end
  error('missing menu choice: ' .. tostring(wanted))
end
require('codeit.ui.input').show = function(opts, callback)
  input_default = opts.default
  callback(table.remove(inputs, 1))
end
local function edit(current, value, selected_scope)
  steps, inputs = { 'max_context_tokens', selected_scope or 'session' }, { value }
  applied = nil
  picker.show(current, function(values, chosen_scope) applied, scope = values, chosen_scope end)
  return applied.max_context_tokens
end
assert(edit(base, ' 64000 ', 'global') == 64000 and scope == 'global')
assert(input_default == 'false' and base.max_context_tokens == false, 'edits only change the draft')
assert(edit(applied, '', 'workspace') == 'auto' and scope == 'workspace')
assert(input_default == '64000')
assert(edit(applied, 'false') == false)
assert(input_default == '')
for _, bad in ipairs({ '0', '-12', 'nonsense', 'inf' }) do
  assert(edit(global, bad) == 32000, 'invalid input preserves the draft limit')
end
assert(edit(global, nil) == 32000, 'cancelling input preserves the draft limit')
local active = true
steps = { 'max_context_tokens' }
require('codeit.ui.input').show = function(_, callback) active = false; callback('1000') end
picker.show(base, function() error('stale settings must not apply') end, function() return active end)
assert(#steps == 0)
print('codeit context limit settings tests passed')
