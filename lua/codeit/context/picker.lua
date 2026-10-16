local M = {}

function M.show(workspace, list, toggle)
  local old = vim.fn.bufnr('codeit://context-files')
  if old ~= -1 and vim.api.nvim_buf_is_valid(old) then
    local win = vim.fn.bufwinid(old)
    if win ~= -1 then vim.api.nvim_win_close(win, true) end
    if vim.api.nvim_buf_is_valid(old) then vim.api.nvim_buf_delete(old, { force = true }) end
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, 'codeit://context-files')
  vim.bo[buf].bufhidden = 'wipe'
  require('codeit.ui.markdown').enable(buf)
  local width = math.max(1, vim.o.columns - 4)
  local height = math.max(1, vim.o.lines - 6)
  if vim.api.nvim_get_mode().mode:sub(1, 1) == 'i' then vim.cmd.stopinsert() end
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor', width = width, height = height,
    row = math.max(0, math.floor((vim.o.lines - height - 2) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = 'minimal', border = 'rounded', title = ' Context files ', title_pos = 'center',
  })
  require('codeit.ui.popup_focus').track(win)
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  local choices = {}
  local function render(row)
    local entries = list()
    choices = {}
    local lines = { '# Additional context files — ' .. workspace,
      'Enter: toggle instructions / cycle skills off → on → active → off  |  q/Esc: close',
      'Skills: off = hidden; on = name/description (except manual-only); active = full instructions. Changes apply to this chat.', '' }
    if #entries == 0 then lines[#lines + 1] = '(No eligible files; check workspace trust and file locations.)' end
    for _, entry in ipairs(entries) do
      local state = '[' .. (entry.state or (entry.included and 'on' or 'off')) .. ']'
      local label = entry.kind == 'skill' and ('skill ' .. entry.name .. (entry.manual_only and ' (manual-only)' or '') .. ': ') or 'instructions: '
      local path = entry.path:gsub('[\r\n]', ' ')
      lines[#lines + 1] = state .. ' ' .. label .. path
      choices[#lines] = entry
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_cursor(win, { math.min(row or 5, #lines), 0 })
    end
  end
  render()
  vim.keymap.set('n', '<CR>', function()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local entry = choices[row]
    if not entry then return end
    local ok, err = toggle(entry)
    if not ok then return vim.notify('codeit: ' .. err, vim.log.levels.WARN) end
    render(row)
  end, { buffer = buf, silent = true, desc = 'Toggle context file' })
  for _, key in ipairs({ 'q', '<Esc>' }) do
    vim.keymap.set('n', key, function()
      if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    end, { buffer = buf, silent = true, desc = 'Close context files' })
  end
end

return M
