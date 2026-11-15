local M = {}

local function width(byte)
  if byte >= 194 and byte <= 223 then return 2 end
  if byte >= 224 and byte <= 239 then return 3 end
  if byte >= 240 and byte <= 244 then return 4 end
  return 1
end

-- Byte limits must not retain only the beginning of a multibyte character.
function M.prefix(text, limit)
  local last = math.min(#text, limit)
  local start = last
  while start > 0 do
    local byte = text:byte(start)
    if byte < 128 or byte > 191 then break end
    start = start - 1
  end
  if start > 0 and start + width(text:byte(start)) - 1 > last then last = start - 1 end
  return text:sub(1, last)
end

-- Neovim's JSON encoder permits invalid UTF-8. Repair only invalid bytes at the
-- transport boundary, leaving the original transcript and valid Unicode intact.
function M.sanitize(text)
  local parts, offset = {}, 1
  while offset <= #text do
    local start = text:find('[\128-\255]', offset)
    if not start then break end
    parts[#parts + 1] = text:sub(offset, start - 1)
    local first = text:byte(start)
    local size = width(first)
    local valid = size > 1 and start + size - 1 <= #text
    for index = start + 1, start + size - 1 do
      local byte = text:byte(index)
      if not byte or byte < 128 or byte > 191 then valid = false end
    end
    local second = text:byte(start + 1)
    if valid and ((first == 224 and second < 160) or (first == 237 and second > 159)
      or (first == 240 and second < 144) or (first == 244 and second > 143)) then valid = false end
    parts[#parts + 1] = valid and text:sub(start, start + size - 1) or '�'
    offset = start + (valid and size or 1)
  end
  parts[#parts + 1] = text:sub(offset)
  return table.concat(parts)
end

return M
