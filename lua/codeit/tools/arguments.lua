local M = {}
local yaml_script = debug.getinfo(1, 'S').source:sub(2):gsub('arguments%.lua$', 'arguments_yaml.py')
local max_bytes = 1024 * 1024

local function object(text)
  local ok, value = pcall(vim.json.decode, text)
  if not ok then return nil, 'invalid JSON' end
  if type(value) ~= 'table' or vim.islist(value) then return nil, 'tool arguments must be a JSON object', true end
  local function finite(item)
    if type(item) == 'number' then return item == item and item ~= math.huge and item ~= -math.huge end
    if type(item) == 'table' then
      for _, child in pairs(item) do if not finite(child) then return false end end
    end
    return true
  end
  if not finite(value) then return nil, 'tool arguments contain a non-finite number', true end
  return value
end

local function cleanup(text)
  text = vim.trim(text)
  local language, body = text:match('^```([%w_-]*)\r?\n(.-)\r?\n```$')
  if body and (language == '' or language == 'json' or language == 'yaml' or language == 'yml') then text = body end
  local parts, quoted, escaped = {}, false, false
  for i = 1, #text do
    local char = text:sub(i, i)
    if quoted then
      if escaped then escaped = false
      elseif char == '\\' then escaped = true
      elseif char == '"' then quoted = false end
      parts[#parts + 1] = char
    elseif char == '"' then
      quoted = true
      parts[#parts + 1] = char
    else
      local trailing = false
      if char == ',' then
        local before = i - 1
        while before > 0 and text:sub(before, before):match('%s') do before = before - 1 end
        local after = text:find('%S', i + 1)
        trailing = text:sub(before, before):match('["}%]%del]')
          and after and text:sub(after, after):match('[}%]]')
      end
      if not trailing then parts[#parts + 1] = char end
    end
  end
  return table.concat(parts)
end

-- Return canonical JSON only when healed, so callers can retain the exact arguments
-- used for approval/execution in subsequent provider requests.
function M.decode(text, enabled)
  if text == nil then text = '{}' end
  if type(text) ~= 'string' then return nil, 'tool arguments must be a JSON string' end
  local value, err, terminal = object(text)
  if value or terminal or enabled ~= true then return value, err end
  if #text > max_bytes then return nil, 'tool arguments exceed the healing limit (1MB)' end
  local cleaned = cleanup(text)
  value, err, terminal = object(cleaned)
  if value then return value, nil, vim.json.encode(value) end
  if terminal then return nil, err end
  -- Isolated Python ignores workspace imports; only this fixed parser receives
  -- model output, via stdin. No shell or YAML object constructors are involved.
  local candidates = { text }
  if cleaned ~= text then candidates[#candidates + 1] = cleaned end
  for _, candidate in ipairs(candidates) do
    local ok, result = pcall(function()
      return vim.system({ 'python3', '-I', yaml_script }, { stdin = candidate, text = true }):wait(1000)
    end)
    if ok and result.code == 0 then
      if #result.stdout > 2 * max_bytes then return nil, 'YAML output exceeds the healing limit' end
      value, err = object(result.stdout)
      if value then return value, nil, result.stdout end
    end
  end
  return nil, 'invalid tool arguments; YAML fallback failed (requires Python 3 and PyYAML)'
end

return M
