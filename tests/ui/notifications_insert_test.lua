-- Actual Insert mode requires editor mode, not -l (see tests/run.sh).
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local ui = require('codeit.ui')
local popup = require('codeit.ui.notifications')
ui.open(function() error('must not send') end, ui.close)
ui.render({}, 'Working', 'test', 'test')
vim.wait(30)
local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
local defer, timers = vim.defer_fn, {}
vim.defer_fn = function(callback) timers[#timers + 1] = callback end
local creation_events = 0
local autocmd = vim.api.nvim_create_autocmd({ 'WinNew', 'BufWinEnter' }, {
  callback = function() creation_events = creation_events + 1 end,
})
local esc = vim.api.nvim_replace_termcodes('<Esc>', true, false, true)
local function run(column, key, prefix, suffix)
  local row = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_buf_set_lines(buf, row - 1, -1, false, { 'abcd' })
  vim.api.nvim_win_set_cursor(win, { row, column })
  local actions = {
    function() popup.notify('first') end,
    function() popup.notify('second') end,
    function() timers[1]() end,
    function() timers[2]() end,
    function() popup.notify('reopened') end,
    function() timers[3]() end,
  }
  local failure, finished
  local function step(index)
    local ok, err = pcall(function()
      assert(vim.fn.mode() == 'i', 'notifications must preserve Insert mode')
      assert(vim.api.nvim_get_current_win() == win, 'notifications must preserve input focus')
      assert(vim.api.nvim_get_current_line() == prefix .. suffix, 'typing must stay at the insertion point')
      if not actions[index] then finished = true; return end
      local cursor = vim.api.nvim_win_get_cursor(win)
      actions[index]()
      assert(vim.deep_equal(vim.api.nvim_win_get_cursor(win), cursor), 'notifications must preserve the cursor')
      assert(creation_events == 0, 'passive notification creation must not trigger input autocommands')
      local text = tostring(index)
      prefix = prefix .. text
      vim.api.nvim_feedkeys(text, 'nt', false)
    end)
    if not ok then failure = err end
    if failure or finished then
      vim.api.nvim_feedkeys(esc, 'nt', false)
    else
      defer(function() step(index + 1) end, 20)
    end
  end
  defer(function() step(1) end, 20)
  vim.api.nvim_feedkeys(key, 'xt!', false)
  assert(not failure, failure)
  assert(finished, 'Insert-mode regression must run to completion')
  timers = {}
end
run(2, 'i', 'ab', 'cd')
run(3, 'a', 'abcd', '')
vim.api.nvim_del_autocmd(autocmd)
vim.defer_fn = defer
ui.close()
print('codeit notification Insert-mode tests passed')
