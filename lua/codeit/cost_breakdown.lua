local M = {}

local functions = { 'main_chat', 'context_review', 'tool_assessment', 'tool_review',
  'compaction', 'cost_review', 'history_summary' }

local function number(value)
  return type(value) == 'number' and value >= 0 and value < math.huge
end

function M.restore(value)
  local result = {}
  if type(value) ~= 'table' then return result end
  for _, name in ipairs(functions) do
    local bucket = value[name]
    if type(bucket) == 'table' and number(bucket.cost) and number(bucket.missing_cost)
      and bucket.missing_cost == math.floor(bucket.missing_cost) and number(bucket.requests)
      and bucket.requests == math.floor(bucket.requests) and bucket.requests >= bucket.missing_cost then
      result[name] = { cost = bucket.cost, missing_cost = bucket.missing_cost, requests = bucket.requests }
    end
  end
  return result
end

function M.add(breakdown, name, amount)
  local bucket = breakdown[name] or { cost = 0, missing_cost = 0, requests = 0 }
  breakdown[name] = bucket
  bucket.requests = bucket.requests + 1
  if amount then bucket.cost = bucket.cost + amount else bucket.missing_cost = bucket.missing_cost + 1 end
end

function M.merge(target, source)
  for name, bucket in pairs(source) do
    local total = target[name] or { cost = 0, missing_cost = 0, requests = 0 }
    target[name] = total
    for _, key in ipairs({ 'cost', 'missing_cost', 'requests' }) do total[key] = total[key] + bucket[key] end
  end
end

return M
