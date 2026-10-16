vim.opt.runtimepath:prepend(vim.fn.getcwd())
local retention = require('codeit.log_retention')
local root = vim.fn.tempname()
vim.fn.mkdir(root .. '/codeit', 'p')
local stdpath, time, date = vim.fn.stdpath, os.time, os.date
local now = 1741564800
vim.fn.stdpath = function(kind) return kind == 'state' and root or stdpath(kind) end
os.time = function() return now end
os.date = function(format, seconds) return date(format, seconds or now) end
local provider = root .. '/codeit/provider-errors.log'
local tool = root .. '/codeit/tool-errors.jsonl'
local age = 3 * 24 * 60 * 60
local function stamp(offset)
  return os.date('!%Y-%m-%dT%H:%M:%S', now + offset)
end
local function provider_entry(offset, text)
  return '[' .. stamp(offset) .. 'Z] test/model: ' .. text
end
local function tool_entry(offset, text, fraction)
  return vim.json.encode({ timestamp = stamp(offset) .. (fraction or '.123456') .. 'Z', error = text })
end
local function read(path) return vim.fn.readfile(path) end
local function equal(actual, expected)
  assert(vim.deep_equal(actual, expected), vim.inspect({ actual = actual, expected = expected }))
end

local recent = provider_entry(-60, 'recent')
local boundary = provider_entry(-age, 'exactly three days')
local future = provider_entry(60, 'future')
vim.fn.writefile({ 'unknown header', provider_entry(-age - 1, 'old'), 'Response: old body',
  'old continuation', recent, 'Response: recent body', '', 'recent continuation', boundary,
  future, provider_entry(-age - 2, 'old tail'), 'old tail body' }, provider)
assert(retention.prune(provider, 'provider'))
equal(read(provider), { 'unknown header', recent, 'Response: recent body', '', 'recent continuation', boundary, future })
assert(vim.fn.readfile(provider, 'b')[#read(provider) + 1] == '', 'retained entries must end in a newline')
if vim.fn.has('unix') == 1 then assert(vim.fn.getfperm(provider) == 'rw-------') end

local recent_tool = tool_entry(-60, 'recent\nmultiline error')
local boundary_tool = tool_entry(-age, 'boundary', '.000000')
local future_tool = tool_entry(60, 'future')
vim.fn.writefile({ tool_entry(-age - 1, 'old', '.999999'), recent_tool, '{broken JSON',
  '{"error":"no timestamp"}', boundary_tool, future_tool, tool_entry(-age - 100, 'old tail') }, tool)
assert(retention.prune(tool, 'tool'))
equal(read(tool), { recent_tool, '{broken JSON', '{"error":"no timestamp"}', boundary_tool, future_tool })
if vim.fn.has('unix') == 1 then assert(vim.fn.getfperm(tool) == 'rw-------') end

-- A log containing only retained entries is not rewritten.
local mkstemp = vim.uv.fs_mkstemp
vim.uv.fs_mkstemp = function() error('unexpected rewrite') end
assert(retention.prune(provider, 'provider'))
assert(retention.prune(tool, 'tool'))
vim.uv.fs_mkstemp = mkstemp

-- Cleanup failures leave the original log intact and remove temporary files.
local stale = { provider_entry(-age - 1, 'old'), 'Response: details' }
vim.fn.writefile(stale, provider)
vim.uv.fs_mkstemp = function() return nil, 'simulated open failure' end
assert(not retention.prune(provider, 'provider'))
equal(read(provider), stale)
vim.uv.fs_mkstemp = mkstemp
for _, operation in ipairs({ 'fs_write', 'fs_rename' }) do
  local original = vim.uv[operation]
  vim.uv[operation] = function() return nil, 'simulated failure' end
  assert(not retention.prune(provider, 'provider'))
  equal(read(provider), stale)
  assert(#vim.fn.glob(provider .. '.*', false, true) == 0, 'temporary file leaked')
  vim.uv[operation] = original
end
assert(retention.prune(provider, 'provider'))
equal(read(provider), {})

-- Both writers prune before appending, even when public setup was not called.
vim.fn.writefile(stale, provider)
require('codeit.providers.log').error({ provider = 'test', model = 'model' }, 'new error', 'new response')
equal(read(provider), { provider_entry(0, 'new error'), 'Response: new response' })
vim.fn.writefile({ tool_entry(-age - 1, 'old') }, tool)
require('codeit.tools.log').finish({ timestamp = stamp(0) .. '.000000Z', tool = 'read_file' }, 'Error: new error')
local records = read(tool)
assert(#records == 1 and vim.json.decode(records[1]).error == 'Error: new error')

-- Setup cleans both logs immediately and installs just one hourly cleanup timer.
local new_timer, timers, tick = vim.uv.new_timer, 0
vim.uv.new_timer = function()
  timers = timers + 1
  return {
    start = function(_, delay, interval, callback)
      assert(delay == 3600000 and interval == 3600000)
      tick = callback
    end,
    unref = function() end,
  }
end
vim.fn.writefile(stale, provider)
vim.fn.writefile({ tool_entry(-age - 1, 'old') }, tool)
local unrelated = root .. '/codeit/settings.json'
vim.fn.writefile({ 'untouched' }, unrelated)
retention.setup()
equal(read(provider), {})
equal(read(tool), {})
retention.setup()
assert(timers == 1)
vim.fn.writefile({ recent }, provider)
vim.fn.writefile({ recent_tool }, tool)
now = now + age
local cleaned = false
tick()
vim.schedule(function() cleaned = true end)
assert(vim.wait(1000, function() return cleaned end))
equal(read(provider), {})
equal(read(tool), {})
equal(read(unrelated), { 'untouched' })
vim.uv.new_timer = new_timer
assert(retention.prune(root .. '/missing.log', 'tool') == false)

vim.fn.stdpath, os.time, os.date = stdpath, time, date
vim.fn.delete(root, 'rf')
print('error log retention: ok')
