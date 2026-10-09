vim.opt.runtimepath:prepend(vim.fn.getcwd())
local runner = require('codeit.process')
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
local result
runner.run({ 'sh', '-c', "printf '%030000d' 0" }, dir, function(value) result = value end)
assert(vim.wait(5000, function() return result ~= nil end))
assert(#result.stdout == 20000 and result.truncated and result.code == 0)

local active, called = true, false
runner.run({ 'sh', '-c', 'sleep 0.4; touch child-finished' }, dir, function() called = true end,
  function() return active end, { poll_ms = 10, kill_after_ms = 30 })
active = false
vim.wait(650, function() return false end)
assert(not called and vim.fn.filereadable(dir .. '/child-finished') == 0,
  'cancelled commands and ordinary descendants must stop, not just hide results')

result = nil
runner.run({ 'sh', '-c', "trap '' TERM; sleep 5" }, dir, function(value) result = value end,
  function() return true end, { timeout_ms = 80, poll_ms = 10, kill_after_ms = 30 })
assert(vim.wait(2000, function() return result ~= nil end), 'SIGTERM-resistant process must complete')
assert(result.timed_out and result.code ~= 0)

-- Even a process API that never delivers exit gets a bounded error, once.
local system = vim.system
local signals, count = {}, 0
vim.system = function()
  return { kill = function(_, signal) signals[#signals + 1] = signal end }
end
runner.run({ 'fake' }, dir, function(value) count = count + 1; result = value end,
  function() return true end, { timeout_ms = 20, poll_ms = 5, kill_after_ms = 10 })
assert(vim.wait(1000, function() return count == 1 end))
assert(vim.deep_equal(signals, { 15, 9 }) and result.timed_out)
vim.wait(50, function() return false end)
assert(count == 1)
vim.system = system
result = nil
runner.run({ 'printf', 'one\ntwo' }, dir, function(value) result = value end,
  nil, { on_stdout = function() error('observer failed') end, kill_after_ms = 10 })
assert(vim.wait(1000, function() return result ~= nil end))
assert(result.code ~= 0 and result.stderr:find('observer failed', 1, true))
vim.fn.delete(dir, 'rf')
print('codeit process tests passed')
