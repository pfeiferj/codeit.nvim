local M = {}
local current
local highlight_ns = vim.api.nvim_create_namespace('codeit_workspace_review')
local trust_highlights = { all = 'DiagnosticOk', tracked = 'DiagnosticWarn', untrusted = 'DiagnosticError' }

local function clean(text) return tostring(text):gsub('%c', ' ') end

function M.show()
  if current and vim.api.nvim_win_is_valid(current) then
    vim.api.nvim_set_current_win(current)
    return current, vim.api.nvim_win_get_buf(current)
  end
  if vim.api.nvim_get_mode().mode:sub(1, 1) == 'i' then vim.cmd.stopinsert() end
  local origin = vim.api.nvim_get_current_win()
  local win, entries, row_entries
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_name(buf, 'codeit://workspaces')
  vim.api.nvim_set_hl(0, 'CodeitTableHeader', { default = true, link = 'Title' })
  vim.api.nvim_set_hl(0, 'CodeitTableBorder', { default = true, link = 'Delimiter' })
  local function render()
    local selected = win and row_entries[vim.api.nvim_win_get_cursor(win)[1]]
    entries, row_entries = require('codeit.workspaces').list(), {}
    local rows = { { 'Workspace', 'Read trust', 'Trust source' } }
    for _, entry in ipairs(entries) do
      local source = 'No trust rule'
      if entry.origin then
        source = (entry.mode == 'untrusted' and 'Revoked' or entry.source)
          .. (entry.origin ~= entry.workspace and (' in ' .. clean(entry.origin)) or ' here')
      end
      rows[#rows + 1] = { clean(entry.workspace), entry.mode, source }
    end
    local lines = { 'Workspaces · Enter: change directory · t: change trust · r: refresh · q/Esc: close',
      'all: all files · tracked: Git-tracked files only · untrusted: no workspace auto-approval',
      'Trust controls reads only. Writes and commands have separate approval policies.', '' }
    local table_lines, highlights = require('codeit.ui.table_popup').format({ rows = rows, alignment = { 'left', 'left', 'left' } })
    local table_offset = #lines
    local first_row = table_offset + 3
    local cursor_row = first_row
    for index, entry in ipairs(entries) do
      local row = first_row + index - 1
      row_entries[row] = entry
      if selected and selected.workspace == entry.workspace then cursor_row = row end
    end
    vim.list_extend(lines, table_lines)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(buf, highlight_ns, 0, -1)
    local function highlight(row, first, last, group)
      vim.api.nvim_buf_set_extmark(buf, highlight_ns, row, first, { end_col = last, hl_group = group })
    end
    for row = 0, 2 do highlight(row, 0, #lines[row + 1], 'Comment') end
    highlight(0, 0, #'Workspaces', 'Title')
    for mode, group in pairs(trust_highlights) do
      local first = lines[2]:find(mode .. ':', 1, true)
      highlight(1, first - 1, first - 1 + #mode, group)
    end
    for _, span in ipairs(highlights) do
      highlight(span[1] + table_offset, span[2], span[3], span[4])
    end
    for index, entry in ipairs(entries) do
      local row = first_row + index - 2
      local path, source = rows[index + 1][1], rows[index + 1][3]
      local trust_start = lines[row + 1]:find(' | ', #path + 3, true) + 2
      local source_start = lines[row + 1]:find(' | ', trust_start + #entry.mode + 1, true) + 2
      highlight(row, 2, 2 + #path, 'Directory')
      highlight(row, trust_start, trust_start + #entry.mode, trust_highlights[entry.mode])
      highlight(row, source_start, source_start + #source, 'Comment')
    end
    vim.bo[buf].modifiable = false
    if win then vim.api.nvim_win_set_cursor(win, { math.min(cursor_row, #lines), 0 }) end
  end
  render()
  local width, height = math.max(1, vim.o.columns - 4), math.max(1, vim.o.lines - 6)
  win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor', width = width, height = height, row = 1, col = 1,
    style = 'minimal', border = 'rounded', title = ' Workspace trust ',
  })
  require('codeit.ui.popup_focus').track(win)
  current = win
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.api.nvim_win_set_cursor(win, { math.min(7, vim.api.nvim_buf_line_count(buf)), 0 })
  local function selection()
    local entry = row_entries[vim.api.nvim_win_get_cursor(win)[1]]
    if not entry then vim.notify('codeit: select a workspace row', vim.log.levels.WARN) end
    return entry
  end
  vim.keymap.set('n', 't', function()
    local entry = selection()
    if not entry then return end
    vim.ui.select({ 'all', 'tracked', 'untrusted' }, {
      prompt = 'Read trust for ' .. clean(entry.workspace) .. ' (applies to descendants unless overridden):',
    }, function(mode)
      if not mode or not vim.api.nvim_win_is_valid(win) then return end
      local ok, err = require('codeit.tools.approval').set_workspace_trust(mode ~= 'untrusted' and mode or nil, entry.workspace)
      if not ok then
        return vim.notify('codeit: could not save workspace trust: ' .. tostring(err), vim.log.levels.ERROR)
      end
      render()
    end)
  end, { buffer = buf, silent = true, desc = 'Change selected workspace trust' })
  vim.keymap.set('n', '<CR>', function()
    local entry = selection()
    if not entry then return end
    -- nvim_win_call restores the cwd afterward, so switch to the origin explicitly.
    local ok, err = pcall(function()
      if vim.api.nvim_win_is_valid(origin) then vim.api.nvim_set_current_win(origin) end
      vim.cmd('cd ' .. vim.fn.fnameescape(entry.workspace))
    end)
    if not ok then
      if vim.api.nvim_win_is_valid(win) then vim.api.nvim_set_current_win(win) end
      return vim.notify('codeit: could not change directory: ' .. tostring(err), vim.log.levels.ERROR)
    end
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    vim.notify('codeit: working directory: ' .. clean(entry.workspace))
  end, { buffer = buf, silent = true, desc = 'Change directory to selected workspace' })
  for _, key in ipairs({ 'q', '<Esc>' }) do
    vim.keymap.set('n', key, function()
      if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    end, { buffer = buf, silent = true })
  end
  vim.keymap.set('n', 'r', render, { buffer = buf, silent = true, desc = 'Refresh workspace trust' })
  vim.api.nvim_create_autocmd('WinClosed', { pattern = tostring(win), once = true, callback = function()
    if current == win then current = nil end
  end })
  return win, buf
end

return M
