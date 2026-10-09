local M = {}

-- All offsets and ranges refer to the original revision, never another edit's output.
function M.apply(lines, edits)
  local text = table.concat(lines, '\n')
  local offsets, position = {}, 1
  for row, line in ipairs(lines) do offsets[row], position = position, position + #line + 1 end
  local replacements = {}
  for index, edit in ipairs(edits) do
    local start, last = edit.start_line or 1, edit.end_line or #lines
    if start < 1 or last < start or last > #lines then return nil, 'invalid edit range for edit ' .. index end
    local region = table.concat(vim.list_slice(lines, start, last), '\n')
    local first = region:find(edit.old_text, 1, true)
    if not first then return nil, 'old_text not found for edit ' .. index .. '; read the file again' end
    if region:find(edit.old_text, first + 1, true) then
      return nil, 'old_text is not unique for edit ' .. index .. '; add context or specify start_line and end_line'
    end
    first = offsets[start] + first - 1
    replacements[#replacements + 1] = { first = first, last = first + #edit.old_text - 1, text = edit.new_text }
  end
  table.sort(replacements, function(a, b) return a.first < b.first end)
  for index = 2, #replacements do
    if replacements[index].first <= replacements[index - 1].last then return nil, 'edits overlap in the original revision' end
  end
  for index = #replacements, 1, -1 do
    local edit = replacements[index]
    text = text:sub(1, edit.first - 1) .. edit.text .. text:sub(edit.last + 1)
  end
  return vim.split(text, '\n', { plain = true })
end

return M
