local M = {}

function M.cost(amount, incomplete)
  return string.format('$%.3f%s', amount, incomplete and '+' or '')
end

function M.tokens(count, scale, suffix)
  local value = string.format('%.3f', count / (scale or 1000000)):gsub('0+$', ''):gsub('%.$', '')
  return value .. (suffix or 'm')
end

return M
