local M = {}

--- Enable Codeit's UI syntax without changing unrelated buffers.
function M.enable(buf)
  vim.keymap.set('n', 'gR', '<Cmd>CodeitRender<CR>',
    { buffer = buf, silent = true, desc = 'View rendered Markdown image' })
  vim.keymap.set('n', 'gT', function() require('codeit.ui.table_popup').show() end,
    { buffer = buf, silent = true, desc = 'View formatted Markdown table' })
  require('codeit.ui.highlight').enable(buf)
end

--- Fence arbitrary text without closing the code block if it contains backticks.
function M.fence(text, language)
  local longest = 2
  for run in text:gmatch('`+') do longest = math.max(longest, #run) end
  local fence = string.rep('`', longest + 1)
  local lines = { fence .. (language or '') }
  vim.list_extend(lines, vim.split(text, '\n', { plain = true }))
  lines[#lines + 1] = fence
  return lines
end

return M
