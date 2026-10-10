vim.opt.runtimepath:prepend(vim.fn.getcwd())
local popup = require('codeit.table_popup')
local lines = { 'Intro', '| Name | Count | Note |', '| :--- | ---: | :---: |',
  '| 界 | 2 | x |', '| longer | 123 | a\\|b |', '', 'Outro' }
for row = 2, 5 do
  local tbl = assert(popup.find(lines, row))
  assert(tbl.first == 2 and tbl.last == 5 and #tbl.rows == 3)
  assert(vim.deep_equal(tbl.alignment, { 'left', 'right', 'center' }))
  local formatted = popup.format(tbl)
  assert(formatted[3] == '| 界     |     2 |  x   |', formatted[3])
  assert(formatted[4] == '| longer |   123 | a|b  |', formatted[4])
  for _, line in ipairs(formatted) do
    assert(vim.fn.strdisplaywidth(line) == vim.fn.strdisplaywidth(formatted[1]))
  end
end
assert(not popup.find(lines, 1) and not popup.find(lines, 6))
assert(popup.find({ 'A | B', '--- | ---', 'one | two' }, 3))
assert(popup.find({ '| A |', '| --- |', '| one |' }, 1))
assert(not popup.find({ '| A | B |', '| -- | --- |' }, 1))
assert(not popup.find({ '| A | B |', '| --- |' }, 1))
for _, fence in ipairs({ '```', '~~~~' }) do
  local fenced = { fence .. 'text' }
  vim.list_extend(fenced, lines)
  fenced[#fenced + 1] = fence
  assert(not popup.find(fenced, 3), 'code blocks are not tables')
  vim.list_extend(fenced, { 'A | B', '--- | ---' })
  assert(popup.find(fenced, #fenced), 'tables after a fence still work')
end
local ragged = popup.format(assert(popup.find({ 'A | B', '--- | ---', 'x |', 'a | b | ignored' }, 3)))
assert(ragged[3] == '| x   |     |')

local source = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(source, 0, -1, false, lines)
require('codeit.markdown').enable(source)
local origin = vim.api.nvim_get_current_win()
for row = 2, 5 do
  vim.api.nvim_win_set_cursor(origin, { row, 1 })
  vim.api.nvim_feedkeys('gT', 'x', false)
  local win = vim.api.nvim_get_current_win()
  assert(win ~= origin and vim.api.nvim_win_get_config(win).relative == 'editor')
  local buf = vim.api.nvim_win_get_buf(win)
  assert(not vim.bo[buf].modifiable and not vim.wo[win].wrap)
  assert(vim.bo[buf].filetype == 'markdown' and vim.bo[buf].syntax == 'markdown')
  assert(vim.b[buf].current_syntax == 'markdown')
  assert(vim.api.nvim_win_get_cursor(win)[1] == 1)
  assert(not vim.wo[win].cursorline)
  local expected = popup.format(popup.find(lines, row))
  table.insert(expected, 1, '')
  assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), expected))
  local marks = vim.api.nvim_buf_get_extmarks(buf,
    vim.api.nvim_create_namespace('codeit_table_popup'), 0, -1, { details = true })
  local header, border = false, false
  for _, mark in ipairs(marks) do
    assert(mark[2] > 0, 'the cursor line must not be highlighted')
    if mark[4].hl_group == 'CodeitTableHeader' then
      header = true
      assert(mark[2] == 1)
    elseif mark[4].hl_group == 'CodeitTableBorder' then
      border = true
    end
  end
  assert(header and border, 'headers and borders must be highlighted')
  local key = row % 2 == 0 and 'q' or vim.api.nvim_replace_termcodes('<Esc>', true, false, true)
  vim.api.nvim_feedkeys(key, 'x', false)
  assert(not vim.api.nvim_win_is_valid(win) and not vim.api.nvim_buf_is_valid(buf))
  assert(vim.api.nvim_get_current_win() == origin)
  assert(vim.api.nvim_win_get_cursor(origin)[1] == row)
end
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(source, 0, -1, false), lines))
local notify = vim.notify
local message
vim.notify = function(text) message = text end
vim.api.nvim_win_set_cursor(origin, { 1, 0 })
assert(popup.show() == nil and message:find('no Markdown table', 1, true))
assert(vim.api.nvim_get_current_win() == origin)
vim.notify = notify

local large = { 'A | B', '--- | ---' }
for _ = 1, vim.o.lines + 10 do large[#large + 1] = string.rep('x', vim.o.columns + 10) .. ' | y' end
vim.api.nvim_buf_set_lines(source, 0, -1, false, large)
vim.api.nvim_win_set_cursor(origin, { #large, 0 })
local win = assert(popup.show())
local config = vim.api.nvim_win_get_config(win)
assert(config.width <= vim.o.columns - 4 and config.height <= vim.o.lines - 4)
assert(vim.api.nvim_win_get_cursor(win)[1] == 1)
assert(vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win)) == #large + 1)
vim.api.nvim_win_close(win, true)
-- A table opened from the chat-preview float must appear above that float.
vim.api.nvim_buf_set_lines(source, 0, -1, false, lines)
local preview = vim.api.nvim_open_win(source, true, {
  relative = 'editor', width = 30, height = 7, row = 0, col = 0, zindex = 80,
})
vim.api.nvim_win_set_cursor(preview, { 4, 0 })
local overlay = assert(popup.show())
assert(vim.api.nvim_win_get_config(overlay).zindex > 80)
vim.api.nvim_win_close(overlay, true)
assert(vim.api.nvim_get_current_win() == preview)
vim.api.nvim_win_close(preview, true)
print('codeit table popup tests passed')
