vim.opt.runtimepath:prepend(vim.fn.getcwd())
local utf8 = require('codeit.utf8')
local valid = 'quotes " backslash \\ controls\n\t\r\0 é — 😀'
assert(utf8.sanitize(valid) == valid)
for _, char in ipairs({ 'é', '—', '😀' }) do
  local text = 'a' .. char .. 'z'
  for limit = 0, #text do
    local expected = limit == 0 and '' or limit < 1 + #char and 'a'
      or limit == 1 + #char and 'a' .. char or text
    assert(utf8.prefix(text, limit) == expected)
  end
  for bytes = 1, #char - 1 do
    local partial = 'a' .. char:sub(1, bytes)
    assert(utf8.prefix(partial, #partial) == 'a')
  end
end
local invalid = {
  string.char(128), string.char(255), string.char(192, 175),
  string.char(224, 128, 128), string.char(237, 160, 128),
  string.char(240, 128, 128, 128), string.char(244, 144, 128, 128),
  string.char(245, 128, 128, 128), string.char(240, 159),
}
for _, bytes in ipairs(invalid) do
  assert(utf8.sanitize('a' .. bytes .. 'z') == 'a' .. string.rep('�', #bytes) .. 'z')
end
assert(utf8.sanitize(string.char(194) .. 'safe') == '�safe')
assert(utf8.sanitize(string.char(194, 128, 244, 143, 191, 191)) == string.char(194, 128, 244, 143, 191, 191))

local helpers = {}
require('codeit.chat.history').attach({}, {}, helpers)
for _, char in ipairs({ 'é', '—', '😀' }) do
  local transcript = helpers.summary_transcript({ messages = {
    { role = 'tool', content = string.rep('b', 499) .. char },
    { role = 'assistant', content = string.rep('a', 1199) .. char },
  } })
  assert(transcript == 'tool: ' .. string.rep('b', 499) .. '\nassistant: ' .. string.rep('a', 1199))
end

local body = { model = 'test', messages = {
  { role = 'assistant', content = valid },
  { role = 'tool', content = 'binary:' .. table.concat(invalid) .. ':end' },
  { role = 'assistant', tool_calls = { { id = 'test', type = 'function',
    ['function'] = { name = 'test', arguments = vim.json.encode({ text = valid }) } } } },
} }
local original = vim.deepcopy(body)
local system, payload = vim.system
vim.system = function(_, options, callback)
  payload = options.stdin
  vim.schedule(function() callback({ code = 0, stdout = '{}\n200' }) end)
  return { kill = function() end }
end
local done = false
require('codeit.providers.http').post('https://example.invalid', {}, body, function(response, err)
  assert(response and not err)
  done = true
end)
assert(vim.wait(1000, function() return done end))
vim.system = system
assert(vim.deep_equal(body, original), 'transport must not mutate stored messages')
assert(vim.json.decode(payload).messages[1].content == valid)
assert(vim.json.decode(vim.json.decode(payload).messages[3].tool_calls[1]['function'].arguments).text == valid)
-- Neovim accepts invalid UTF-8 JSON, so use a strict decoder as an independent check.
local check = vim.system({ 'python3', '-I', '-c',
  'import sys,json; json.loads(sys.stdin.buffer.read().decode("utf-8"))' }, { stdin = payload, text = true }):wait()
assert(check.code == 0, check.stderr)
print('UTF-8 request boundaries: passed')
