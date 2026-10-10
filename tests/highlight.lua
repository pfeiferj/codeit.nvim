vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.cmd('syntax off')
local unrelated = vim.api.nvim_get_current_buf()
vim.bo[unrelated].filetype = 'lua'
local buf = vim.api.nvim_create_buf(false, true)
local lines = {
  '# Codeit', '**You**', '**bold** and *italic* and `inline`', '- item', '[link](https://example.com)',
  '```json', '{"enabled": true}', '```',
  '```bash', 'if true; then echo "$HOME"; fi', '```',
  '~~~python', 'def greet():', '    return "hello"', '~~~',
  '````text', '# literal heading', '```python', '**literal bold**', '````',
  '```unknown-language', '# also literal', '```', '# After blocks',
}
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
require('codeit.markdown').enable(buf)
vim.api.nvim_set_current_buf(buf)
assert(vim.bo[buf].filetype == 'codeit' and vim.bo[buf].syntax == 'codeit')
assert(vim.b[buf].current_syntax == 'codeit')
assert(vim.bo[unrelated].filetype == 'lua' and vim.bo[unrelated].syntax == '')
assert(vim.g.syntax_on == nil, 'enabling Codeit must not enable global syntax')

local function group(text, token)
  local row
  for index, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line == text then row = index; break end
  end
  assert(row, 'missing line: ' .. text)
  local col = token and assert(text:find(token, 1, true)) or 1
  return vim.api.nvim_buf_call(buf, function()
    return vim.fn.synIDattr(vim.fn.synID(row, col, true), 'name')
  end)
end
assert(group('# Codeit') == 'CodeitHeading')
assert(group('**You**') == 'CodeitUser')
assert(group(lines[3], 'bold') == 'CodeitBold')
assert(group(lines[3], 'italic') == 'CodeitItalic')
assert(group(lines[3], 'inline') == 'CodeitInlineCode')
assert(group('- item') == 'CodeitList')
assert(group(lines[5]) == 'CodeitLink')
assert(group(lines[7], 'true'):match('^json'), group(lines[7], 'true'))
assert(group(lines[10], 'if'):match('^sh'), group(lines[10], 'if'))
assert(group('def greet():', 'def'):match('^python'), group('def greet():', 'def'))
assert(group('    return "hello"', 'return'):match('^python'))
assert(group('```json') == 'CodeitFence')
for _, text in ipairs({ '# literal heading', '```python', '**literal bold**', '# also literal' }) do
  assert(group(text) == 'CodeitCodeBlock', text .. ': ' .. group(text))
end
assert(group('# After blocks') == 'CodeitHeading')

-- Hidden buffers and streamed/newly edited fence labels must acquire syntax too.
vim.api.nvim_set_current_buf(unrelated)
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { '```lua', 'local value = true', '```', '# After stream' })
assert(vim.wait(1000, function() return group('local value = true', 'local'):match('^lua') ~= nil end))
assert(group('# After stream') == 'CodeitHeading')
local count = vim.api.nvim_buf_line_count(buf)
vim.api.nvim_buf_set_lines(buf, count - 4, count, false, { '```py', 'import os', '```', '# After edit' })
assert(vim.wait(1000, function() return group('import os'):match('^python') ~= nil end))
assert(group('# After edit') == 'CodeitHeading')

-- A malformed string in a language block must not consume the closing fence.
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { '```python', 'value = """unfinished', '```', '# Recovered' })
assert(group('# Recovered') == 'CodeitHeading')
require('codeit.markdown').enable(buf)
assert(group('# Recovered') == 'CodeitHeading', 'enabling twice should be harmless')

-- Exercise the syntax runtime entry point with normal syntax loading enabled.
vim.cmd('syntax on')
local fresh = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(fresh)
vim.bo[fresh].filetype = 'codeit'
assert(vim.b[fresh].current_syntax == 'codeit')
vim.api.nvim_buf_delete(buf, { force = true })
vim.wait(10)
print('Codeit highlighting tests passed')
