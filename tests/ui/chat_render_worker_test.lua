-- The optional renderer needs Node, but no npm packages or Chromium are
-- required to exercise its CommonJS/ESM loader compatibility.
if vim.fn.executable('node') ~= 1 then
  print('chat_render_worker_test: skipped (Node.js not installed)')
  return
end
local result = vim.system({ 'node', '--test', 'tests/ui/chat_render_worker_test.js' },
  { text = true, timeout = 10000 }):wait()
assert(result.code == 0, (result.stdout or '') .. (result.stderr or ''))
print('chat_render_worker_test: passed')
