-- Actual Insert mode requires editor mode, not -l (see tests/run.sh).
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local input = require('codeit.ui.input')
local esc = vim.api.nvim_replace_termcodes('<Esc>', true, false, true)
for _, default in ipairs({ 'vendor/model', 'café', '界', '' }) do
  local result
  local buf
  vim.keymap.set('n', '<F5>', function()
    input.show({ prompt = 'Value', default = default }, function(value) result = value end)
    buf = vim.api.nvim_get_current_buf()
  end)
  local failure, finished
  vim.defer_fn(function()
    local ok, err = pcall(function()
      assert(vim.fn.mode() == 'i', 'input must automatically enter Insert mode')
      assert(vim.api.nvim_win_get_cursor(0)[2] == #default, 'cursor must follow the entire default value')
      vim.api.nvim_feedkeys('x', 'nt', false)
    end)
    if not ok then failure = err end
    vim.defer_fn(function()
      local checked, check_err = pcall(function()
        assert(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == default .. 'x',
          'typing must append after the default, including multibyte characters')
      end)
      if not checked then failure = failure or check_err end
      finished = true
      vim.api.nvim_feedkeys(esc, 'nt', false)
    end, 20)
  end, 20)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<F5>', true, false, true), 'xt!', false)
  vim.keymap.del('n', '<F5>')
  assert(not failure, failure)
  assert(finished, 'input typing regression must run to completion')
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
    if map.lhs == '<CR>' then map.callback(); break end
  end
  assert(result == default .. 'x', 'submission must retain appended text')
end
print('codeit input Insert-mode tests passed')
