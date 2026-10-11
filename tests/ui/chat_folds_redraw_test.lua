-- Run with: nvim --headless -u NONE -c 'luafile tests/ui/chat_folds_redraw_test.lua'
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local ui = require('codeit.ui')
ui.open(function() error('must not send') end, ui.close)
local sidebar, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
local messages = {
  { role = 'user', content = 'Request' },
  { role = 'assistant', reasoning_details = { { text = 'PRIVATE reasoning' } }, tool_calls = {
    { id = 'read', ['function'] = { name = 'read_file', arguments = '{}' } },
  } },
  { role = 'tool', tool_call_id = 'read', content = 'PRIVATE result' },
  { role = 'assistant', content = 'Answer' },
  { role = 'user', content = 'Next' },
}
local marker = '<!-- codeit:activity-end -->'
local function render()
  ui.render(messages, 'Working', 'test', 'test')
  local expected = ui.chat_lines()
  assert(vim.deep_equal(expected, vim.api.nvim_buf_get_lines(buf, 0, #expected, false)),
    'staging must preserve the complete rendered transcript')
  for _, win in ipairs({ sidebar, vim.api.nvim_get_current_win() }) do
    vim.api.nvim_win_call(win, function()
      for row, level in pairs(vim.w[win].codeit_fold_levels) do
        if level == '<1' then
          local ending = vim.api.nvim_buf_get_lines(buf, tonumber(row) - 2, tonumber(row), false)
          assert(ending[1] == marker and ending[2] == '',
            'every activity fold must end with its explicit marker and blank guard row')
          assert(vim.fn.foldlevel(tonumber(row) - 1) == 1 and vim.fn.foldlevel(tonumber(row)) == 1,
            'the marker and guard row must both belong inside the activity fold')
        end
      end
    end)
  end
end
render()
ui.toggle_popup()
local popup = vim.api.nvim_get_current_win()
for _, win in ipairs({ sidebar, popup }) do
  vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
end

local set_lines, set_text, cmd = vim.api.nvim_buf_set_lines, vim.api.nvim_buf_set_text, vim.cmd
local expect_closed, checked_redraws = true, 0
local function check_redraw()
  cmd('redraw')
  checked_redraws = checked_redraws + 1
  if not expect_closed then return end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for _, win in ipairs({ sidebar, popup }) do
    vim.api.nvim_win_call(win, function()
      for row, line in ipairs(lines) do
        if line:find('PRIVATE', 1, true) or line == marker then
          assert(vim.fn.foldclosed(row) ~= -1,
            'an intermediate redraw must not expose activity text or its end marker')
        end
      end
    end)
  end
end
vim.api.nvim_buf_set_lines = function(target, ...)
  if target == buf then check_redraw() end
  local result = set_lines(target, ...)
  if target == buf then check_redraw() end
  return result
end
vim.api.nvim_buf_set_text = function(target, ...)
  if target == buf then check_redraw() end
  local result = set_text(target, ...)
  if target == buf then check_redraw() end
  return result
end
vim.cmd = setmetatable({}, { __index = cmd, __call = function(_, command)
  local result = cmd(command)
  if command:find('zX', 1, true) then check_redraw() end
  return result
end })

local insert_error, inserted
vim.defer_fn(function()
  local ok, err = pcall(function()
    assert(vim.fn.mode() == 'i', 'redraw regression must exercise actual Insert mode')
    math.randomseed(71)
    for _ = 1, 120 do
      messages[2].reasoning_details[1].text = string.rep('PRIVATE reasoning\n\n', math.random(0, 8))
      messages[2].content = string.rep('Public explanation\n\n', math.random(0, 3))
      messages[3].content = string.rep('PRIVATE result\n\n', math.random(0, 8))
      messages[4].content = string.rep('Public answer\n\n', math.random(0, 5))
      render()
    end
    -- Expanded views must still receive their complete content and retain their state.
    messages[2].reasoning_details[1].text = 'PRIVATE reasoning'
    messages[2].content = nil
    messages[3].content = 'PRIVATE result'
    render()
    expect_closed = false
    for _, win in ipairs({ sidebar, popup }) do
      vim.api.nvim_win_call(win, function() cmd('normal! zR') end)
    end
    messages[2].reasoning_details[1].text = 'PRIVATE revised reasoning\nsecond line'
    messages[3].content = 'PRIVATE revised result'
    render()
    for _, win in ipairs({ sidebar, popup }) do
      vim.api.nvim_win_call(win, function()
        for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
          if line:find('PRIVATE', 1, true) or line == marker then
            assert(vim.fn.foldclosed(row) == -1, 'expanded activity and its end marker must remain visible')
          end
        end
      end)
    end
    assert(vim.fn.mode() == 'i', 'rendering must preserve Insert mode')
    inserted = true
  end)
  if not ok then insert_error = err end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'n', false)
end, 20)
vim.api.nvim_feedkeys('i', 'xt!', false)
vim.api.nvim_buf_set_lines, vim.api.nvim_buf_set_text, vim.cmd = set_lines, set_text, cmd
if insert_error or not inserted or checked_redraws < 10 then
  io.stderr:write(tostring(insert_error or 'intermediate redraw regression did not run') .. '\n')
  vim.cmd('cquit')
end
ui.close()
vim.cmd('qa!')
