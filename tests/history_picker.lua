vim.opt.runtimepath:prepend(vim.fn.getcwd())
local picker = require('codeit.history_picker')
local summary = 'Implemented the requested changes and verified that the long LLM summary remains readable.'
local entries = {
  { id = 'first', updated_at = 1000000000, summary = summary },
  { id = 'second', updated_at = 999999999 },
}
local chosen, calls
local function show(items)
  chosen, calls = nil, 0
  picker.show(items, '/a/workspace', function(chat)
    calls = calls + 1
    chosen = chat
  end)
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  assert(vim.bo[buf].filetype == 'markdown' and vim.bo[buf].syntax == 'markdown')
  assert(vim.b[buf].current_syntax == 'markdown', 'history picker should load Markdown highlighting')
  vim.api.nvim_win_call(win, function()
    assert(vim.fn.synIDattr(vim.fn.synID(1, 1, true), 'name') ~= '',
      'history heading should have active Markdown highlighting')
    assert(vim.fn.synIDattr(vim.fn.synID(3, 3, true), 'name') ~= '',
      'history entries should have active Markdown highlighting')
  end)
  local config = vim.api.nvim_win_get_config(win)
  assert(config.relative == 'editor' and config.width >= math.floor(vim.o.columns * 0.8),
    'history picker should occupy most of the editor width')
  assert(config.height <= vim.o.lines - 4)
  if #items == 2 then
    assert(config.height > #items + 2, 'wrapped summaries should have enough vertical room to read')
  end
  assert(vim.wo[win].wrap and vim.wo[win].linebreak)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  assert(lines[1] == '# Resume chat for /a/workspace')
  assert(lines[3] == '- **' .. os.date('%Y-%m-%d %H:%M', items[1].updated_at) .. '**  ' .. summary)
  assert(lines[4] == '- **' .. os.date('%Y-%m-%d %H:%M', items[2].updated_at) .. '**'
    .. (items[2].summary and '  ' .. items[2].summary or ''),
    'each entry should display its timestamp and available summary')
  assert(vim.api.nvim_win_get_cursor(win)[1] == 3)
  return win, buf
end
local win, buf = show(entries)
vim.api.nvim_win_set_cursor(win, { 4, 0 })
vim.api.nvim_buf_call(buf, function() vim.cmd.normal('\r') end)
assert(calls == 1 and chosen == entries[2] and not vim.api.nvim_win_is_valid(win),
  'Enter should resume the chat under the cursor')
vim.wait(20)
assert(calls == 1, 'closing after selection should not trigger a second callback')
win, buf = show(entries)
vim.api.nvim_buf_call(buf, function() vim.cmd.normal('q') end)
assert(calls == 1 and chosen == nil and not vim.api.nvim_win_is_valid(win), 'q should dismiss the picker')
win = show(entries)
vim.api.nvim_win_close(win, true)
assert(vim.wait(100, function() return calls == 1 end) and chosen == nil,
  'closing the floating window should dismiss the picker exactly once')
local many = {}
for i = 1, 100 do many[i] = { id = tostring(i), updated_at = 1000000000 - i, summary = summary } end
win = show(many)
assert(vim.api.nvim_win_get_config(win).height < #many, 'long histories should scroll inside the picker')
vim.api.nvim_win_close(win, true)
print('codeit history picker tests passed')
