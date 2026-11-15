vim.opt.runtimepath:prepend(vim.fn.getcwd())
local format = require('codeit.tools.approval.format')
local executable, system = vim.fn.executable, vim.system
vim.fn.executable = function(name)
  if name == 'shfmt' then return 0 end
  return executable(name)
end

local json = format.call('read_file', { path = 'a`b.lua', end_line = 20, options = { nested = true, items = { 1, 2 } } })
assert(json:find('# read_file\n\n```json\n{\n', 1, true), json)
assert(json:find('  "end_line": 20,\n  "options": {\n    "items": [\n      1,\n      2\n    ],\n    "nested": true\n  },\n  "path": "a`b.lua"\n}', 1, true), json)
assert(vim.deep_equal(vim.json.decode(json:match('```json\n(.-)\n```')), {
  path = 'a`b.lua', end_line = 20, options = { nested = true, items = { 1, 2 } },
}))
local empty = format.call('git_status', vim.empty_dict())
assert(empty == '# git_status\n\n```json\n{}\n```', empty)
local ticks = format.call('fetch_url', { url = '```' })
assert(ticks:find('````json\n', 1, true), ticks)
local bash = format.call('run_command', { argv = { 'printf', '%s\\n', "it's safe; $(touch /tmp/no)", 'a b' } })
assert(bash == "# run_command\n\n```bash\nprintf '%s\\n' 'it'\\''s safe; $(touch /tmp/no)' 'a b'\n```", bash)
local long = format.call('run_command', { argv = { 'git', 'log', '--oneline', '--decorate', '--max-count=10', '--format=%h %s', 'src/a long path', 'other/path' } })
assert(long:find('git \\\n  log \\\n  --oneline', 1, true), long)
assert(long:find("'src/a long path'", 1, true), long)
for _, tool in ipairs({ 'run_command', 'start_background_task' }) do
  for _, shell in ipairs({ 'sh', '/bin/sh', 'bash', '/usr/bin/bash' }) do
    local argv = { shell, '-c', "echo 'one'\necho two | cat" }
    local script = format.call(tool, { argv = argv })
    assert(script:find("```bash\necho 'one'\necho two | cat\n```", 1, true), script)
    assert(vim.deep_equal(argv, { shell, '-c', "echo 'one'\necho two | cat" }))
  end
end
for _, argv in ipairs({
  { 'sh', '-c', 'echo "$0"', 'name' },
  { 'sh', '-c' },
  { 'sh', '-x', '-c', 'echo one' },
  { 'python', '-c', 'print(1)' },
}) do
  local wrapped = format.call('run_command', { argv = argv })
  assert(wrapped:find('```bash\n' .. argv[1] .. ' ', 1, true), wrapped)
end
local script_ticks = format.call('run_command', { argv = { 'sh', '-c', 'echo ```' } })
assert(script_ticks:find('````bash\necho ```\n````', 1, true), script_ticks)
local fallback = format.call('run_command', { argv = 'bad' })
assert(fallback:find('```json\n{\n  "argv": "bad"\n}', 1, true), fallback)
local extra = format.call('run_command', { argv = { 'echo', 'hello' }, flag = false })
assert(extra:find('```bash\necho hello\n```\n\nOther arguments:\n\n```json\n{\n  "flag": false\n}\n```', 1, true), extra)
local source = 'if true; then\necho "hello; world"\nfi'
local formatted = 'if true; then\n  echo "hello; world"\nfi\n'
vim.fn.executable = function(name)
  assert(name == 'shfmt', name)
  return 1
end
for _, shell in ipairs({ 'sh', '/bin/bash' }) do
  vim.system = function(argv, opts)
    assert(vim.deep_equal(argv, { 'shfmt', '-ln', shell == 'sh' and 'posix' or 'bash', '-i', '2' }))
    assert(opts.stdin == source and opts.text == true)
    return { wait = function(_, timeout)
      assert(timeout == 1000)
      return { code = 0, stdout = formatted }
    end }
  end
  local pretty = format.call('run_command', { argv = { shell, '-c', source } })
  assert(pretty:find('```bash\n' .. formatted .. '```', 1, true), pretty)
end
for _, failure in ipairs({ 'exit', 'spawn', 'empty' }) do
  vim.system = function()
    if failure == 'spawn' then error('failed to start') end
    return { wait = function()
      return { code = failure == 'exit' and 1 or 0, stdout = '' }
    end }
  end
  local raw = format.call('run_command', { argv = { 'sh', '-c', source } })
  assert(raw:find('```bash\n' .. source .. '\n```', 1, true), raw)
end
vim.fn.executable, vim.system = executable, system
if executable('shfmt') == 1 then
  local pretty = format.call('run_command', { argv = { 'sh', '-c', source } })
  assert(pretty:find('```bash\n' .. formatted .. '```', 1, true), pretty)
end
print('codeit approval formatting tests passed')
