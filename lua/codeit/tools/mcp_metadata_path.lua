local M = {}

function M.parse(path)
  if type(path) ~= 'string' or #path > 1024 or path:sub(1, 1) ~= '$' then return nil end
  local keys, pos = {}, 2
  while pos <= #path and #keys < 32 do
    local ch = path:sub(pos, pos)
    if ch == '.' then
      local key = path:match('^([%a_][%w_-]*)', pos + 1)
      if not key then return nil end
      keys[#keys + 1], pos = key, pos + #key + 1
    elseif ch == '[' and path:sub(pos + 1, pos + 1) == '"' then
      local last = pos + 2
      while last <= #path and path:sub(last, last) ~= '"' do
        last = last + (path:sub(last, last) == '\\' and 2 or 1)
      end
      if path:sub(last + 1, last + 1) ~= ']' then return nil end
      local ok, key = pcall(vim.json.decode, path:sub(pos + 1, last))
      if not ok or type(key) ~= 'string' then return nil end
      keys[#keys + 1], pos = key, last + 2
    elseif ch == '[' then
      local index = path:match('^(%d+)%]', pos + 1)
      if not index or #index > 8 then return nil end
      keys[#keys + 1], pos = tonumber(index) + 1, pos + #index + 2
    else
      return nil
    end
  end
  if pos > #path and #keys > 0 then return keys end
end

function M.get(value, keys)
  for _, key in ipairs(keys) do
    if type(value) ~= 'table' then return nil end
    value = value[key]
  end
  if value ~= vim.NIL then return value end
end

return M
