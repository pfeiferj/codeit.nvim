vim.opt.runtimepath:prepend(vim.fn.getcwd())
local decode = require('codeit.tools.arguments').decode
local function equal(actual, expected)
  assert(vim.deep_equal(actual, expected), vim.inspect(actual) .. ' ~= ' .. vim.inspect(expected))
end
local system = vim.system
vim.system = function() error('strict JSON / JSON repairs must not invoke Python') end
local args, err, canonical = decode('{"path":"file.lua","include_external":false}')
equal(args, { path = 'file.lua', include_external = false })
assert(not err and not canonical)
assert(decode('{}'))
assert(decode(nil))
for _, text in ipairs({ '[]', '[1]', 'null', 'true', '42', '"text"' }) do
  assert(not decode(text, true), text)
end
assert(not decode({}, true))
assert(not decode('{"path":"file.lua",}'))
assert(not decode('{"path":"file.lua",}', false))
args, err, canonical = decode('```json\n{"path":"file.lua","edits":[{"old_text":"a","new_text":"b",},],}\n```', true)
equal(args, { path = 'file.lua', edits = { { old_text = 'a', new_text = 'b' } } })
assert(not err and canonical)
equal(vim.json.decode(canonical), args)
args = decode('{"content":"literal ,} and ,] and \\\" quoted","argv":["x",],}', true)
equal(args, { content = 'literal ,} and ,] and " quoted', argv = { 'x' } })
args, err = decode('path: file.lua', true)
assert(not args and err:find('YAML fallback', 1, true))
assert(not decode(string.rep('x', 1024 * 1024 + 1), true))
local timeout
vim.system = function(argv, opts)
  assert(argv[1] == 'python3' and argv[2] == '-I')
  assert(opts.stdin == 'path: file.lua')
  return { wait = function(_, ms) timeout = ms; return { code = 124 } end }
end
assert(not decode('path: file.lua', true))
assert(timeout == 1000)
local original = '```yaml\n{path: "file.lua",}\n```'
local repaired = '{path: "file.lua"}'
local attempts = {}
vim.system = function(_, opts)
  attempts[#attempts + 1] = opts.stdin
  return { wait = function()
    if #attempts == 1 then return { code = 1 } end
    return { code = 0, stdout = '{"path":"file.lua"}' }
  end }
end
args, err, canonical = decode(original, true)
equal(attempts, { original, repaired })
equal(args, { path = 'file.lua' })
equal(vim.json.decode(canonical), args)

-- Prefer the original YAML even when cleanup would alter its quoted strings.
original = "{content: 'literal,}'}"
attempts = {}
vim.system = function(_, opts)
  attempts[#attempts + 1] = opts.stdin
  return { wait = function() return { code = 0, stdout = '{"content":"literal,}"}' } end }
end
args = decode(original, true)
equal(attempts, { original })
assert(args.content == 'literal,}')

attempts = {}
vim.system = function(_, opts)
  attempts[#attempts + 1] = opts.stdin
  return { wait = function() return { code = 1 } end }
end
assert(not decode("```yaml\npath: [\n```", true))
equal(attempts, { "```yaml\npath: [\n```", 'path: [' })
assert(not decode('path: [', true))
assert(#attempts == 3, 'unchanged input must not be retried')
vim.system = system

local available = pcall(function()
  assert(system({ 'python3', '-I', '-c', 'import yaml' }, { text = true }):wait(1000).code == 0)
end)
if available then
  args, err, canonical = decode([[```yaml
path: file.lua
edits:
  - old_text: 'single quoted'
    new_text: |-
      first line
      second line
include_external: false
start_line: 1
metadata: {nothing: null, empty_array: [], empty_object: {}}
```]], true)
  assert(args, err)
  assert(args.path == 'file.lua' and args.include_external == false and args.start_line == 1)
  assert(args.edits[1].new_text == 'first line\nsecond line')
  assert(args.metadata.nothing == vim.NIL)
  assert(vim.islist(args.metadata.empty_array) and not vim.islist(args.metadata.empty_object))
  equal(vim.json.decode(canonical), args)
  args = decode([[{path: 'file.lua', content: 'literal,} and literal,]', argv: [echo, 'yes', '01']}]], true)
  assert(args.content == 'literal,} and literal,]')
  equal(args.argv, { 'echo', 'yes', '01' })
  args = decode('path: yes\ncontent: 2026-01-01\nstart_line: 1e2', true)
  assert(args.path == 'yes' and args.content == '2026-01-01' and args.start_line == 100)
  for _, text in ipairs({
    'path:', '{"path":}', '{"path":"unfinished}',
    'path: one\npath: two', 'path: &value file.lua', 'path: *value',
    'path: !!str file.lua', 'path: !!python/object/apply:os.system [echo unsafe]',
    'path: file.lua\n---\npath: other.lua', '- path: file.lua',
    'true: value', '<<: {path: file.lua}', 'path: .nan', 'start_line: 1e9999',
    'path: [', '```python\npath: file.lua\n```',
    'path: ' .. string.rep('[', 70) .. '1' .. string.rep(']', 70),
  }) do
    local value = decode(text, true)
    assert(not value, 'must reject: ' .. text .. '\n' .. vim.inspect(value))
  end
else
  print('YAML integration cases skipped: Python 3 + PyYAML not installed')
end
print('Tool argument JSON healing: passed')
