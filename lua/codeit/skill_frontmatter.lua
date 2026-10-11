local M = {}

local escapes = {
  ['0'] = '\0', a = '\7', b = '\8', t = '\t', n = '\n', v = '\11', f = '\12', r = '\r',
  e = '\27', [' '] = ' ', ['"'] = '"', ['/'] = '/', ['\\'] = '\\',
  N = '\194\133', _ = '\194\160', L = '\226\128\168', P = '\226\128\169',
}

local function quoted(value)
  local quote, parts, i = value:sub(1, 1), {}, 2
  while i <= #value do
    local char = value:sub(i, i)
    if char == quote then
      if quote == "'" and value:sub(i + 1, i + 1) == "'" then
        parts[#parts + 1], i = "'", i + 2
      else
        local tail = value:sub(i + 1)
        if tail ~= '' and not tail:match('^%s+$') and not tail:match('^%s+#') then return nil end
        return table.concat(parts)
      end
    elseif quote == '"' and char == '\\' then
      local escape = value:sub(i + 1, i + 1)
      local width = ({ x = 2, u = 4, U = 8 })[escape]
      if width then
        local hex = value:sub(i + 2, i + 1 + width)
        if #hex ~= width or not hex:match('^%x+$') then return nil end
        local code = tonumber(hex, 16)
        if code > 0x10ffff or (code >= 0xd800 and code <= 0xdfff) then return nil end
        parts[#parts + 1], i = vim.fn.nr2char(code), i + 2 + width
      else
        if not escapes[escape] then return nil end
        parts[#parts + 1], i = escapes[escape], i + 2
      end
    else
      parts[#parts + 1], i = char, i + 1
    end
  end
end

local function block(lines, row, header)
  header = vim.trim((header:gsub('%s+#.*$', '')))
  local style, modifiers = header:sub(1, 1), header:sub(2)
  local chomp, indent = '', nil
  for char in modifiers:gmatch('.') do
    if char == '+' or char == '-' then
      if chomp ~= '' then return nil end
      chomp = char
    elseif char:match('[1-9]') then
      if indent then return nil end
      indent = tonumber(char)
    else
      return nil
    end
  end
  local values = {}
  for i = row + 1, #lines do
    local line = lines[i]
    if line:match('^%S') then break end
    if line:match('^%s*$') then
      values[#values + 1] = ''
    else
      local spaces = #line:match('^ *')
      indent = indent or spaces
      if indent == 0 or spaces < indent then return nil end
      values[#values + 1] = line:sub(indent + 1)
    end
  end
  local parts, previous = {}, nil
  for i, value in ipairs(values) do
    local next_value = values[i + 1]
    local separator = '\n'
    if style == '>' and next_value then
      -- Fold ordinary lines, but preserve paragraph breaks and more-indented text.
      local ordinary = value ~= '' and not value:match('^%s')
      local next_ordinary = next_value ~= '' and not next_value:match('^%s')
      if ordinary and next_ordinary then
        separator = ' '
      elseif value == '' and next_ordinary and previous and previous ~= '' and not previous:match('^%s') then
        separator = ''
      end
    end
    parts[#parts + 1] = value .. separator
    if value ~= '' then previous = value end
  end
  local result = table.concat(parts)
  if chomp == '-' then return (result:gsub('\n+$', '')) end
  if chomp == '+' then return result end
  return result ~= '' and (result:gsub('\n+$', '') .. '\n') or ''
end

local function scalar(lines, row, value)
  value = vim.trim(value)
  local first = value:sub(1, 1)
  if first == '|' or first == '>' then return block(lines, row, value) end
  for i = row + 1, #lines do
    if not lines[i]:match('^%s*$') then
      if lines[i]:match('^%s') then return nil end
      break
    end
  end
  if first == '"' or first == "'" then return quoted(value) end
  value = vim.trim((value:gsub('%s+#.*$', '')))
  if value == '' or value:sub(1, 1) == '#' or value:match('^[%[%]{},&*!>@`]')
    or value:match('^[-?:]%s') or value:match(':%s') or value:sub(-1) == ':' then return nil end
  local lower = value:lower()
  if lower == 'null' or lower == 'true' or lower == 'false' or value == '~'
    or tonumber(value) or lower:match('^[+-]?%.inf$') or lower == '.nan' then return nil end
  return value
end

local function frontmatter(content)
  local lines = vim.split(content:gsub('\r\n', '\n'), '\n', { plain = true })
  if not lines[1]:match('^%-%-%-%s*$') then return nil end
  local frontmatter, closed = {}, false
  for i = 2, #lines do
    if lines[i]:match('^%-%-%-%s*$') then closed = true; break end
    frontmatter[#frontmatter + 1] = lines[i]
  end
  return closed and frontmatter or nil
end

function M.description(content)
  local frontmatter = frontmatter(content)
  if not frontmatter then return nil end
  local description, found
  for row, line in ipairs(frontmatter) do
    local value = line:match('^description:%s*(.*)$')
    if value then
      if found then return nil end
      found = true
      description = scalar(frontmatter, row, value)
    end
  end
  return description and vim.trim(description) ~= '' and description or nil
end

function M.disable_model_invocation(content)
  local lines = frontmatter(content)
  if not lines then return false end
  local disabled, found = false, false
  for row, line in ipairs(lines) do
    local value = line:match('^disable%-model%-invocation:%s*(.*)$')
    if value then
      -- An ambiguous opt-out must not silently enable model invocation.
      if found then return true end
      found = true
      value = vim.trim((value:gsub('%s+#.*$', ''))):lower()
      disabled = value ~= 'false'
      for i = row + 1, #lines do
        if not lines[i]:match('^%s*$') then
          if lines[i]:match('^%s') then return true end
          break
        end
      end
    end
  end
  return disabled
end

return M
