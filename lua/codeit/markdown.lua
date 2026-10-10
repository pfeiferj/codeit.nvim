local M = {}

--- Load Markdown highlighting in this buffer even when the user's global syntax is off.
--- Do not change the syntax setting for unrelated buffers.
function M.enable(buf)
  vim.keymap.set('n', 'gT', function() require('codeit.table_popup').show() end,
    { buffer = buf, silent = true, desc = 'View formatted Markdown table' })
  vim.bo[buf].filetype = 'markdown'
  vim.bo[buf].syntax = 'markdown'
  if not vim.b[buf].current_syntax then
    vim.api.nvim_buf_call(buf, function() vim.cmd('runtime! syntax/markdown.vim') end)
  end
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
