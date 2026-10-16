-- Actual Insert mode requires editor mode, not -l (see tests/run.sh).
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local ui = require('codeit.ui')
ui.open(function() error('must not send') end, ui.close)
local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
local messages = {
  { role = 'user', content = 'Request' },
  { role = 'assistant', content = 'Initial response' },
}
local function render()
  ui.render(messages, 'Working', 'test', 'test', nil, nil, false)
end
render()
local esc = vim.api.nvim_replace_termcodes('<Esc>', true, false, true)
local function run(draft, column, key, prefix, suffix)
  local row = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_buf_set_lines(buf, row - 1, -1, false, { draft })
  vim.api.nvim_win_set_cursor(win, { row, column })
  local updates = {
    'Streaming response',
    'Streaming response\nAnother line',
    string.rep('Wrapped response ', 80),
    'Short response',
  }
  local failure, finished
  local function step(index)
    local ok, err = pcall(function()
      assert(vim.fn.mode() == 'i', 'streaming must preserve Insert mode')
      assert(vim.api.nvim_get_current_win() == win, 'streaming must preserve input focus')
      assert(vim.api.nvim_get_current_line() == prefix .. suffix, 'typing must stay at the insertion point')
      if not updates[index] then finished = true; return end
      messages[2].content = updates[index]
      render()
      local cursor = vim.api.nvim_win_get_cursor(win)
      assert(cursor[1] == vim.api.nvim_buf_line_count(buf), 'cursor must follow the draft row')
      assert(cursor[2] == #prefix, 'streaming must preserve the insertion column')
      prefix = prefix .. tostring(index)
      vim.api.nvim_feedkeys(tostring(index), 'nt', false)
    end)
    if not ok then failure = err end
    if failure or finished then
      vim.api.nvim_feedkeys(esc, 'nt', false)
    else
      vim.defer_fn(function() step(index + 1) end, 20)
    end
  end
  vim.defer_fn(function() step(1) end, 20)
  vim.api.nvim_feedkeys(key, 'xt!', false)
  assert(not failure, failure)
  assert(finished, 'Insert-mode streaming regression must run to completion')
end
run('abcd', 3, 'a', 'abcd', '')
run('abcd', 2, 'i', 'ab', 'cd')
run('café', 3, 'a', 'café', '')
ui.close()
print('codeit streaming cursor Insert-mode tests passed')
