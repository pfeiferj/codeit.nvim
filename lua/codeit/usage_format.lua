local M = {}

function M.cost(amount, incomplete)
  return string.format('$%.3f%s', amount, incomplete and '+' or '')
end

function M.tokens(count, scale, suffix)
  local value = string.format('%.3f', count / (scale or 1000000)):gsub('0+$', ''):gsub('%.$', '')
  return value .. (suffix or 'm')
end

function M.subscription(snapshot, compact)
  local windows = {}
  for _, name in ipairs({ 'primary', 'secondary' }) do
    local window = snapshot and snapshot[name]
    if window then
      local minutes = window.window_minutes
      local label = compact and name:sub(1, 1) or name
      if minutes then
        if minutes % 1440 == 0 then label = (minutes / 1440) .. 'd'
        elseif minutes % 60 == 0 then label = (minutes / 60) .. 'h'
        else label = minutes .. 'm' end
      end
      local expired = window.reset_at and window.reset_at <= os.time()
      if compact then
        windows[#windows + 1] = label .. ':' .. (expired and '?' or string.format('%.0f%%', window.used_percent))
      else
        windows[#windows + 1] = label .. ' ' .. (expired and 'unknown' or string.format('%g%% used', window.used_percent))
      end
    end
  end
  if compact then return #windows > 0 and table.concat(windows, ' | ') or 'Quota ?' end
  return 'Codex: ' .. (#windows > 0 and table.concat(windows, ' · ') or 'usage unknown')
end

function M.with_subscription(label, amount, incomplete, dollars)
  return label .. ((dollars or amount > 0 or incomplete) and (' (' .. M.cost(amount, incomplete) .. ')') or '')
end

function M.turn_cost(turn)
  local count, dollars = require('codeit.cost_breakdown').subscription_requests(turn.cost_by_function)
  if count > 0 then return M.with_subscription('Subscription', turn.cost, turn.missing_cost > 0, dollars) end
  return M.cost(turn.cost, turn.missing_cost > 0)
end

return M
