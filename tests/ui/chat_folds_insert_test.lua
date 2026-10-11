-- Run with: nvim --headless -u NONE -c 'luafile tests/ui/chat_folds_insert_test.lua'
-- Unlike -l script mode, this exercises the editor's Insert-mode fold updates.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local ui = require('codeit.ui')
ui.open(function() error('must not send') end, ui.close)
local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
local messages = {}
local function render()
  ui.render(messages, 'Working', 'test', 'test')
end
local function row(text)
  for index, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line == text then return index end
  end
  error('missing line: ' .. text)
end
local function toggle(line)
  vim.api.nvim_win_set_cursor(win, { line, 0 })
  vim.cmd('normal! za')
end
render()
vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
local set_text = vim.api.nvim_buf_set_text
local checked_writes = 0
local expect_closed = true
vim.api.nvim_buf_set_text = function(target, first, column, last, end_column, replacement)
  local function check()
    if target ~= buf then return end
    for index, line in ipairs(replacement) do
      if line:match('^%*%*Tool:') or line:match('^%*Calling') or line == 'Insert result' then
        local line_number = first + index
        assert(vim.fn.foldlevel(line_number) == 1, 'streamed tool text must only have the activity fold')
        assert((vim.fn.foldclosed(line_number) ~= -1) == expect_closed,
          'streamed tool text must respect activity expansion during writes')
        checked_writes = checked_writes + 1
      end
    end
  end
  check()
  local result = set_text(target, first, column, last, end_column, replacement)
  check()
  return result
end
local insert_error, inserted
vim.defer_fn(function()
  local ok, err = pcall(function()
    assert(vim.fn.mode() == 'i', 'regression must render in actual Insert mode')
    messages[1] = { role = 'assistant', reasoning_details = { { type = 'reasoning.text', text = 'Inspect first.' } } }
    render()
    toggle(row('**Activity**'))
    expect_closed = false
    vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
    messages[1].tool_calls = { { id = 'search', ['function'] = { name = 'search_workspace', arguments = '{}' } } }
    render()
    assert(vim.fn.foldclosed(row('*Calling `search_workspace`…*')) == -1,
      'new tool calls should remain visible in an expanded activity group')
    toggle(row('**Activity**'))
    expect_closed = true
    vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
    messages[#messages + 1] = { role = 'tool', tool_call_id = 'search', content = 'Insert result' }
    render()
    assert(vim.fn.foldclosed(row('**Tool: search_workspace**')) == row('**Activity**'), 'new results must stay in the closed section')
    toggle(row('**Activity**'))
    assert(vim.fn.foldclosed(row('Inspect first.')) == -1, 'opening activity must reveal reasoning in Insert mode')
    assert(vim.fn.foldclosed(row('**Tool: search_workspace**')) == -1)
    -- Preserve a closed section while adding a separate activity group.
    toggle(row('**Activity**'))
    vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
    messages[#messages + 1] = { role = 'assistant', content = 'Explanation', tool_calls = {
      { id = 'read', ['function'] = { name = 'read_file', arguments = '{}' } },
    } }
    render()
    assert(vim.fn.foldclosed(row('Inspect first.')) == row('**Activity**'))
    assert(vim.fn.foldclosed(row('*Calling `read_file`…*')) ~= -1, 'new sections must be folded in Insert mode')
    toggle(row('**Activity**'))
    assert(vim.fn.foldclosed(row('Inspect first.')) == -1, 'opening activity must reveal reasoning after recomputation')
    assert(vim.fn.mode() == 'i', 'rendering must not leave Insert mode')
    inserted = true
  end)
  if not ok then insert_error = err end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'n', false)
end, 20)
-- x! waits in Insert mode for the timer, rather than immediately leaving it.
vim.api.nvim_feedkeys('i', 'xt!', false)
vim.api.nvim_buf_set_text = set_text
if insert_error or not inserted or checked_writes == 0 then
  io.stderr:write(tostring(insert_error or 'Insert-mode streaming regression did not run') .. '\n')
  vim.cmd('cquit')
end
ui.close()
vim.cmd('qa!')
