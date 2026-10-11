local M = {}

-- Explicit filtering works with stock vim.ui and enhanced UI plugins alike.
function M.search(models, query)
  local matches = {}
  query = query:lower()
  for _, model in ipairs(models) do
    local text = (model.id .. ' ' .. (model.name or '') .. ' ' .. (model.description or '')):lower()
    local match = true
    for word in query:gmatch('%S+') do
      if not text:find(word, 1, true) then match = false; break end
    end
    if match then matches[#matches + 1] = model end
  end
  return matches
end

local function price(value, multiplier)
  local number = (type(value) == 'string' or type(value) == 'number') and tonumber(value)
  if not number or number < 0 or number == math.huge or number ~= number then return 'unknown' end
  return '$' .. string.format('%.6f', number * multiplier):gsub('0+$', ''):gsub('%.$', '')
end

function M.endpoint_label(endpoint)
  local pricing = type(endpoint.pricing) == 'table' and endpoint.pricing or {}
  local name = type(endpoint.provider_name) == 'string' and endpoint.provider_name or endpoint.tag
  local label = name .. ' [' .. endpoint.tag .. ']'
    .. ' — input ' .. price(pricing.prompt, 1000000) .. ', output ' .. price(pricing.completion, 1000000)
    .. ' / 1M tokens'
  if pricing.request ~= nil and pricing.request ~= vim.NIL and tonumber(pricing.request) ~= 0 then
    label = label .. '; ' .. price(pricing.request, 1) .. ' / request'
  end
  if type(endpoint.quantization) == 'string' then label = label .. ' (' .. endpoint.quantization .. ')' end
  return label
end

return M
