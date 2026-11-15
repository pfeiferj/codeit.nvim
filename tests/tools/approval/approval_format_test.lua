vim.opt.runtimepath:prepend(vim.fn.getcwd())
local format = require('codeit.tools.approval.format')
local executable, system = vim.fn.executable, vim.system
vim.fn.executable = function(name)
  if name == 'shfmt' or name == 'black' or name == 'prettier' then return 0 end
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
  { 'python3', '-c', 'print(1)', 'argument' },
  { 'python', '-c' },
  { 'python3', '-I', '-c', 'print(1)' },
  { 'python-script', '-c', 'print(1)' },
  { 'node', '-e' },
  { 'node', '-e', 'console.log(1)', 'argument' },
  { 'node', '--input-type=module', '-e', 'console.log(1)' },
  { 'node-script', '-e', 'console.log(1)' },
  { 'node', 'script.js' },
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
local js_source = 'const x={value:1};console.log(x)'
local js_formatted = 'const x = { value: 1 };\nconsole.log(x);\n'
for _, tool in ipairs({ 'run_command', 'start_background_task' }) do
  for _, node in ipairs({ 'node', 'nodejs', '/usr/bin/node', '/opt/bin/nodejs' }) do
    for _, flag in ipairs({ '-e', '--eval' }) do
      local argv = { node, flag, js_source }
      local raw = format.call(tool, { argv = argv, flag = false })
      assert(raw:find('```javascript\n' .. js_source .. '\n```', 1, true), raw)
      assert(raw:find('Other arguments:', 1, true), raw)
      assert(vim.deep_equal(argv, { node, flag, js_source }))
    end
  end
end
local js_ticks = format.call('run_command', { argv = { 'node', '-e', 'console.log("```")' } })
assert(js_ticks:find('````javascript\nconsole.log("```")\n````', 1, true), js_ticks)
vim.fn.executable = function(name)
  assert(name == 'prettier', name)
  return 1
end
vim.system = function(argv, opts)
  assert(vim.deep_equal(argv, { 'prettier', '--no-config', '--no-editorconfig', '--parser', 'babel' }))
  assert(opts.stdin == js_source and opts.text == true)
  return { wait = function(_, timeout)
    assert(timeout == 1000)
    return { code = 0, stdout = js_formatted }
  end }
end
for _, tool in ipairs({ 'run_command', 'start_background_task' }) do
  local pretty = format.call(tool, { argv = { 'node', '-e', js_source } })
  assert(pretty:find('```javascript\n' .. js_formatted .. '```', 1, true), pretty)
end
for _, failure in ipairs({ 'exit', 'spawn', 'empty', 'timeout' }) do
  vim.system = function()
    if failure == 'spawn' then error('failed to start') end
    return { wait = function()
      return { code = failure == 'timeout' and 124 or (failure == 'exit' and 1 or 0), stdout = '' }
    end }
  end
  local raw = format.call('run_command', { argv = { 'node', '--eval', js_source } })
  assert(raw:find('```javascript\n' .. js_source .. '\n```', 1, true), raw)
end
vim.fn.executable = function(name)
  if name == 'shfmt' or name == 'black' or name == 'prettier' then return 0 end
  return executable(name)
end
local python_source = 'x={"value":1};print(x)'
local python_formatted = 'x = {"value": 1}\nprint(x)\n'
for _, tool in ipairs({ 'run_command', 'start_background_task' }) do
  for _, python in ipairs({ 'python', 'python3', '/usr/bin/python3', '/opt/bin/python3.12' }) do
    local argv = { python, '-c', python_source }
    local raw = format.call(tool, { argv = argv, flag = false })
    assert(raw:find('```python\n' .. python_source .. '\n```', 1, true), raw)
    assert(raw:find('Other arguments:', 1, true), raw)
    assert(vim.deep_equal(argv, { python, '-c', python_source }))
  end
end
local python_ticks = format.call('run_command', { argv = { 'python3', '-c', 'print("```")' } })
assert(python_ticks:find('````python\nprint("```")\n````', 1, true), python_ticks)
vim.fn.executable = function(name)
  assert(name == 'black', name)
  return 1
end
vim.system = function(argv, opts)
  local empty_config = vim.fn.has('win32') == 1 and 'NUL' or '/dev/null'
  assert(vim.deep_equal(argv, { 'black', '--config', empty_config, '--quiet', '-' }))
  assert(opts.stdin == python_source and opts.text == true)
  return { wait = function(_, timeout)
    assert(timeout == 1000)
    return { code = 0, stdout = python_formatted }
  end }
end
local python_pretty = format.call('run_command', { argv = { 'python3', '-c', python_source } })
assert(python_pretty:find('```python\n' .. python_formatted .. '```', 1, true), python_pretty)
for _, failure in ipairs({ 'exit', 'spawn', 'empty', 'timeout' }) do
  vim.system = function()
    if failure == 'spawn' then error('failed to start') end
    return { wait = function()
      return { code = failure == 'timeout' and 124 or (failure == 'exit' and 1 or 0), stdout = '' }
    end }
  end
  local raw = format.call('run_command', { argv = { 'python', '-c', python_source } })
  assert(raw:find('```python\n' .. python_source .. '\n```', 1, true), raw)
end
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
if executable('black') == 1 then
  local pretty = format.call('run_command', { argv = { 'python3', '-c', python_source } })
  assert(pretty:find('```python\n' .. python_formatted .. '```', 1, true), pretty)
end
if executable('prettier') == 1 then
  local pretty = format.call('run_command', { argv = { 'node', '-e', js_source } })
  assert(pretty:find('```javascript\n' .. js_formatted .. '```', 1, true), pretty)
end
print('codeit approval formatting tests passed')
