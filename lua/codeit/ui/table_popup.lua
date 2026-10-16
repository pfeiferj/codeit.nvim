local M = {}
local highlight_ns = vim.api.nvim_create_namespace('codeit_table_popup')

-- Split unescaped pipes; optional outer pipes are not cells.
local function cells(line)
  line = vim.trim(line)
  local result, cell, pipes = {}, {}, 0
  local index = 1
  while index <= #line do
    local char = line:sub(index, index)
    if char == '\\' and line:sub(index + 1, index + 1) == '|' then
      cell[#cell + 1] = '|'
      index = index + 2
    elseif char == '|' then
      result[#result + 1] = vim.trim(table.concat(cell))
      cell = {}
      pipes = pipes + 1
      index = index + 1
    else
      cell[#cell + 1] = char
      index = index + 1
    end
  end
  if pipes == 0 then return nil end
  result[#result + 1] = vim.trim(table.concat(cell))
  if line:sub(1, 1) == '|' then table.remove(result, 1) end
  if line:sub(-1) == '|' and #cell == 0 then table.remove(result) end
  return result
end

--- Find a pipe table containing row, excluding fenced code blocks.
function M.find(lines, row)
  local fenced, fence_char, fence_length = {}, nil, nil
  for index, line in ipairs(lines) do
    local run, rest = line:match('^%s*([`~]+)(.*)$')
    if run and #run >= 3 and (run:match('^`+$') or run:match('^~+$')) then
      if not fence_char then
        fence_char, fence_length = run:sub(1, 1), #run
        fenced[index] = true
      elseif run:sub(1, 1) == fence_char and #run >= fence_length and vim.trim(rest) == '' then
        fenced[index] = true
        fence_char, fence_length = nil, nil
      else
        fenced[index] = true
      end
    else
      fenced[index] = fence_char ~= nil
    end
  end
  for separator = 2, #lines do
    local header = not fenced[separator - 1] and cells(lines[separator - 1])
    local markers = not fenced[separator] and cells(lines[separator])
    if header and markers and #header > 0 and #header == #markers then
      local alignment, valid = {}, true
      for index, marker in ipairs(markers) do
        if not marker:match('^:?%-%-%-+:?$') then valid = false; break end
        alignment[index] = marker:sub(-1) == ':'
          and (marker:sub(1, 1) == ':' and 'center' or 'right') or 'left'
      end
      if valid then
        local rows, last = { header }, separator
        while last < #lines and not fenced[last + 1] do
          local data = cells(lines[last + 1])
          if not data then break end
          rows[#rows + 1] = data
          last = last + 1
        end
        if row >= separator - 1 and row <= last then
          return { rows = rows, alignment = alignment, first = separator - 1, last = last }
        end
      end
    end
  end
end

function M.format(tbl)
  local widths = {}
  for col = 1, #tbl.alignment do
    widths[col] = 3
    for _, row in ipairs(tbl.rows) do
      widths[col] = math.max(widths[col], vim.fn.strdisplaywidth(row[col] or ''))
    end
  end
  local lines, highlights = {}, {}
  for index, row in ipairs(tbl.rows) do
    local parts = {}
    for col, width in ipairs(widths) do
      local text = row[col] or ''
      local padding = width - vim.fn.strdisplaywidth(text)
      local left = tbl.alignment[col] == 'right' and padding
        or (tbl.alignment[col] == 'center' and math.floor(padding / 2) or 0)
      parts[col] = string.rep(' ', left) .. text .. string.rep(' ', padding - left)
    end
    lines[#lines + 1] = '| ' .. table.concat(parts, ' | ') .. ' |'
    local line, offset = #lines - 1, 0
    highlights[#highlights + 1] = { line, 0, 1, 'CodeitTableBorder' }
    for _, part in ipairs(parts) do
      if index == 1 then
        highlights[#highlights + 1] = { line, offset + 2, offset + 2 + #part, 'CodeitTableHeader' }
      end
      offset = offset + 2 + #part + 1
      highlights[#highlights + 1] = { line, offset, offset + 1, 'CodeitTableBorder' }
    end
    if index == 1 then
      local rules = {}
      for col, width in ipairs(widths) do rules[col] = string.rep('-', width) end
      lines[#lines + 1] = '+-' .. table.concat(rules, '-+-') .. '-+'
      highlights[#highlights + 1] = { #lines - 1, 0, #lines[#lines], 'CodeitTableBorder' }
    end
  end
  return lines, highlights
end

function M.show()
  local origin = vim.api.nvim_get_current_win()
  local source = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local tbl = M.find(vim.api.nvim_buf_get_lines(source, 0, -1, false), row)
  if not tbl then
    vim.notify('codeit: no Markdown table under the cursor', vim.log.levels.INFO)
    return
  end
  local lines, highlights = M.format(tbl)
  local width = 1
  table.insert(lines, 1, '')
  for _, line in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(line)) end
  width = math.min(width, math.max(1, vim.o.columns - 4))
  local height = math.min(#lines, math.max(1, vim.o.lines - 4))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  require('codeit.ui.markdown').enable(buf)
  vim.api.nvim_set_hl(0, 'CodeitTableHeader', { default = true, link = 'Title' })
  vim.api.nvim_set_hl(0, 'CodeitTableBorder', { default = true, link = 'Delimiter' })
  for _, span in ipairs(highlights) do
    vim.api.nvim_buf_set_extmark(buf, highlight_ns, span[1] + 1, span[2], {
      end_col = span[3], hl_group = span[4],
    })
  end
  vim.bo[buf].modifiable = false
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor', width = width, height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = 'minimal', border = 'rounded', title = ' Table · q/Esc: close ', title_pos = 'center',
    zindex = math.max(50, vim.api.nvim_win_get_config(origin).zindex or 50) + 1,
  })
  require('codeit.ui.popup_focus').track(win)
  vim.wo[win].wrap = false
  vim.wo[win].scrolloff = 0
  vim.wo[win].conceallevel = 0
  vim.wo[win].list = false
  vim.wo[win].cursorline = false
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  for _, key in ipairs({ 'q', '<Esc>' }) do
    vim.keymap.set('n', key, function()
      if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    end, { buffer = buf, silent = true, desc = 'Close formatted table' })
  end
  return win
end

return M
