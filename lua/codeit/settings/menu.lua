local M = {}
local ns = vim.api.nvim_create_namespace('codeit_settings_menu')

-- A local selector: settings should not depend on a fuzzy-picker UI override.
function M.select(items, opts, callback)
  opts = opts or {}
  local lines = { '  Enter: select   j/k or arrows: move   /: search   q/Esc: back' }
  local choices, spans, section = {}, {}, nil
  local function highlight(row, first, last, group)
    spans[#spans + 1] = { row - 1, first, last, group }
  end
  highlight(1, 0, #lines[1], 'CodeitSettingsHint')
  for index, item in ipairs(items) do
    local group = type(item) == 'table' and item.section or nil
    if group and group ~= section then
      lines[#lines + 1] = ''
      lines[#lines + 1] = '  ' .. group
      highlight(#lines, 0, #lines[#lines], 'CodeitSettingsHeading')
      section = group
    end
    local label = opts.format_item and opts.format_item(item) or tostring(item)
    -- Catalog text must remain a single selectable row.
    label = label:gsub('%c', ' ')
    lines[#lines + 1] = '  ' .. label
    choices[#lines] = index
    local colon = label:find(':', 1, true)
    if colon then
      highlight(#lines, 2, colon + 2, 'CodeitSettingsLabel')
      highlight(#lines, colon + 2, #lines[#lines], 'CodeitSettingsValue')
    else
      highlight(#lines, 2, #lines[#lines], group == 'Apply changes' and 'CodeitSettingsAction' or 'CodeitSettingsLabel')
    end
  end
  if #items == 0 then
    lines[#lines + 1] = '  No choices available.'
    highlight(#lines, 0, #lines[#lines], 'CodeitSettingsHint')
  end
  local links = { Heading = 'Title', Label = 'Normal', Value = 'String', Hint = 'Comment', Action = 'Special' }
  for name, link in pairs(links) do
    vim.api.nvim_set_hl(0, 'CodeitSettings' .. name, { default = true, link = link })
  end
  local origin = vim.api.nvim_get_current_win()
  local width = math.max(1, vim.o.columns - 4)
  local height = math.max(1, math.min(#lines, vim.o.lines - 6))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'codeit-settings'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for _, span in ipairs(spans) do
    vim.api.nvim_buf_set_extmark(buf, ns, span[1], span[2], { end_col = span[3], hl_group = span[4] })
  end
  vim.bo[buf].modifiable = false
  if vim.api.nvim_get_mode().mode:sub(1, 1) == 'i' then vim.cmd.stopinsert() end
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor', width = width, height = height,
    row = math.max(0, math.floor((vim.o.lines - height - 2) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = 'minimal', border = 'rounded', title = ' ' .. (opts.prompt or 'Settings') .. ' ', title_pos = 'center',
    zindex = math.max(50, vim.api.nvim_win_get_config(origin).zindex or 50) + 1,
  })
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.wo[win].scrolloff = 2
  local first = 1
  for row, index in pairs(choices) do
    if index == (opts.selected or 1) then first = row; break end
  end
  vim.api.nvim_win_set_cursor(win, { first, 0 })
  local finished = false
  local function finish(item, index)
    if finished then return end
    finished = true
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    callback(item, index)
  end
  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(win), once = true,
    callback = function() vim.schedule(function() finish(nil) end) end,
  })
  local function move(direction)
    local row = vim.api.nvim_win_get_cursor(win)[1] + direction
    while row >= 1 and row <= #lines do
      if choices[row] then vim.api.nvim_win_set_cursor(win, { row, 0 }); return end
      row = row + direction
    end
  end
  for key, direction in pairs({ j = 1, k = -1, ['<Down>'] = 1, ['<Up>'] = -1 }) do
    vim.keymap.set('n', key, function() move(direction) end, { buffer = buf, silent = true })
  end
  vim.keymap.set('n', '<CR>', function()
    local index = choices[vim.api.nvim_win_get_cursor(win)[1]]
    if index then finish(items[index], index) end
  end, { buffer = buf, silent = true, desc = 'Select setting under cursor' })
  for _, key in ipairs({ 'q', '<Esc>' }) do
    vim.keymap.set('n', key, function() finish(nil) end, { buffer = buf, silent = true, desc = 'Leave settings menu' })
  end
  return win, buf
end

return M
