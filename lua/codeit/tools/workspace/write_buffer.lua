local M = {}

--- Save approved edits only when the buffer was clean before the edit.
--- Use Neovim's normal write path so autocommands and file encoding are respected.
function M.finish(id, was_modified)
  if was_modified then return 'Applied edit to buffer (not saved: existing unwritten changes)' end
  if vim.api.nvim_buf_get_name(id) == '' then
    return 'Applied edit to buffer (not saved: buffer has no file name)'
  end
  local ok, err = pcall(vim.api.nvim_buf_call, id, function()
    vim.cmd('silent keepalt write')
  end)
  if not ok then return 'Error: edit applied but could not save file: ' .. tostring(err) end
  if vim.bo[id].modified then return 'Error: edit applied but buffer still has unwritten changes after write' end
  return 'Applied edit and saved file'
end

return M
