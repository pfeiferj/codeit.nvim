vim.opt.runtimepath:prepend(vim.fn.getcwd())
local temp = vim.fn.tempname()
vim.fn.mkdir(temp .. '/one', 'p')
vim.fn.mkdir(temp .. '/two', 'p')
vim.fn.chdir(temp .. '/one')
local requests = {}
package.loaded['codeit.providers'] = {
  chat = function(_, _, specs, callback)
    requests[#requests + 1] = specs
    callback({ role = 'assistant', content = 'ok' })
  end,
}
local plugin = require('codeit')
local settings = require('codeit.settings')
local approval = require('codeit.tools.approval')
vim.fn.delete(vim.fn.stdpath('data') .. '/codeit/settings.json')
local validator_calls = 0
local function setup(enabled)
  plugin.setup({ max_context_tokens = false, context_review = false, approval = {
    tool_call_risk = enabled,
    validators = { function() validator_calls = validator_calls + 1; return 'reject' end },
    read_commands = { { argv = { 'inspect' } } },
  } })
end
local function check(enabled)
  assert(plugin.get_settings().approval.tool_call_risk == enabled)
  assert(approval.uses_tool_call_risk() == enabled, 'settings must update approval at runtime')
  plugin.send('Check the current tool schemas')
  for _, definition in ipairs(requests[#requests]) do
    local params = definition['function'].parameters
    assert((params.properties.risk_score ~= nil) == enabled, 'next request must use the selected mode')
  end
end
setup(false)
check(false)
local base = plugin.get_settings()
assert(vim.deep_equal(base.approval, { tool_call_risk = false }), 'snapshots exclude setup-only approval options')
local global = vim.deepcopy(base)
global.approval.tool_call_risk = true
assert(plugin.configure(global, 'global'))
check(true)
setup(false)
check(true)
local workspace = vim.deepcopy(base)
assert(plugin.configure(workspace, 'workspace'))
check(false)
setup(true)
check(false)
vim.fn.chdir(temp .. '/two')
check(true)
assert(plugin.configure(base))
check(false)
setup(false)
check(true)
local legacy = vim.deepcopy(base)
legacy.approval = nil
assert(plugin.configure(legacy))
check(true)
legacy.approval = {}
assert(plugin.configure(legacy))
check(true)
assert(settings.save(legacy, 'workspace', require('codeit.chat.storage').workspace()))
setup(false)
check(true)
vim.fn.chdir(temp .. '/one')
check(false)
assert(settings.save(legacy, 'workspace', require('codeit.chat.storage').workspace()))
setup(false)
check(true)
assert(plugin.configure(base))
local decision
approval.request('run_command', { argv = { 'inspect' } }, 'Inspect', nil, function(value) decision = value end)
assert(validator_calls > 0 and decision == 'Rejected by approval policy', 'changing risk settings must preserve configured validators')
for _, bad in ipairs({ false, 'yes', { tool_call_risk = 'true' }, { tool_call_risk = 1 }, { validators = {} } }) do
  local values = vim.deepcopy(base)
  values.approval = bad
  assert(not settings.validate(values), 'invalid approval settings must be rejected')
  assert(not plugin.configure(values))
end
print('codeit tool-call risk settings tests passed')
