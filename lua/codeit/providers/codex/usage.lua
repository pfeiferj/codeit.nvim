local M = {}

local function number(value)
  local n = (type(value) == 'number' or type(value) == 'string') and tonumber(value)
  if n and n >= 0 and n < math.huge then return n end
end

local function window(raw)
  if type(raw) ~= 'table' then return end
  local used = number(raw.used_percent)
  if not used or used > 100 then return end
  local minutes, reset = number(raw.window_minutes), number(raw.reset_at)
  return { used_percent = used, window_minutes = minutes and minutes > 0 and minutes or nil,
    reset_at = reset }
end

-- Header names and units follow the Codex CLI's codex-api/src/rate_limits.rs.
function M.parse(headers, event)
  local fields, result = {}, {}
  for line in (headers or ''):gmatch('[^\r\n]+') do
    local name, value = line:match('^([^:]+):%s*(.-)%s*$')
    if name then fields[name:lower()] = value end
  end
  local limits
  if type(event) == 'table' and (event.metered_limit_name == nil or event.metered_limit_name == 'codex')
    and (event.limit_name == nil or event.limit_name == 'codex') then
    limits = type(event.rate_limits) == 'table' and event.rate_limits or nil
  end
  for _, name in ipairs({ 'primary', 'secondary' }) do
    local prefix = 'x-codex-' .. name .. '-'
    result[name] = (limits and window(limits[name])) or window({
      used_percent = fields[prefix .. 'used-percent'], window_minutes = fields[prefix .. 'window-minutes'],
      reset_at = fields[prefix .. 'reset-at'],
    })
  end
  return next(result) and result or nil
end

return M
