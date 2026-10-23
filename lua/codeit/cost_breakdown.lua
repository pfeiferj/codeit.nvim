local M = {}

local functions = { 'main_chat', 'context_review', 'tool_assessment', 'tool_review',
  'compaction', 'cost_review', 'history_summary', 'subagent', 'personal_wiki' }
local token_fields = { { 'tokens_in', 'missing_in' }, { 'tokens_out', 'missing_out' } }

local function number(value)
  return type(value) == 'number' and value >= 0 and value < math.huge
end

local function empty()
  return { cost = 0, missing_cost = 0, requests = 0,
    tokens_in = 0, tokens_out = 0, missing_in = false, missing_out = false }
end

function M.restore(value)
  local result = {}
  if type(value) ~= 'table' then return result end
  for _, name in ipairs(functions) do
    local bucket = value[name]
    if type(bucket) == 'table' and number(bucket.cost) and number(bucket.missing_cost)
      and bucket.missing_cost == math.floor(bucket.missing_cost) and number(bucket.requests)
      and bucket.requests == math.floor(bucket.requests) and bucket.requests >= bucket.missing_cost then
      local restored = { cost = bucket.cost, missing_cost = bucket.missing_cost, requests = bucket.requests }
      if number(bucket.subscription_requests) and bucket.subscription_requests == math.floor(bucket.subscription_requests)
        and bucket.subscription_requests > 0 and bucket.subscription_requests <= bucket.requests then
        restored.subscription_requests = bucket.subscription_requests
      end
      for _, pair in ipairs(token_fields) do
        restored[pair[1]] = number(bucket[pair[1]]) and bucket[pair[1]] or 0
        restored[pair[2]] = bucket[pair[2]] == true or not number(bucket[pair[1]])
      end
      result[name] = restored
    end
  end
  return result
end

function M.add(breakdown, name, amount, tokens_in, tokens_out, subscription)
  local bucket = breakdown[name] or empty()
  breakdown[name] = bucket
  bucket.requests = bucket.requests + 1
  if subscription then bucket.subscription_requests = (bucket.subscription_requests or 0) + 1 end
  if amount then bucket.cost = bucket.cost + amount else bucket.missing_cost = bucket.missing_cost + 1 end
  local counts = { tokens_in, tokens_out }
  for index, pair in ipairs(token_fields) do
    local count = counts[index]
    bucket[pair[2]] = bucket[pair[2]] == true or not number(bucket[pair[1]]) or not number(count)
    bucket[pair[1]] = (number(bucket[pair[1]]) and bucket[pair[1]] or 0) + (number(count) and count or 0)
  end
end

function M.merge(target, source)
  for name, bucket in pairs(source) do
    local total = target[name] or empty()
    target[name] = total
    if (bucket.subscription_requests or 0) > 0 then
      total.subscription_requests = (total.subscription_requests or 0) + bucket.subscription_requests
    end
    for _, key in ipairs({ 'cost', 'missing_cost', 'requests' }) do total[key] = total[key] + bucket[key] end
    for _, pair in ipairs(token_fields) do
      total[pair[2]] = total[pair[2]] == true or bucket[pair[2]] == true
        or not number(total[pair[1]]) or not number(bucket[pair[1]])
      total[pair[1]] = (number(total[pair[1]]) and total[pair[1]] or 0)
        + (number(bucket[pair[1]]) and bucket[pair[1]] or 0)
    end
  end
end

function M.subscription_requests(breakdown)
  local count, dollars = 0, false
  for _, bucket in pairs(breakdown or {}) do
    count = count + (bucket.subscription_requests or 0)
    dollars = dollars or bucket.requests > (bucket.subscription_requests or 0)
  end
  return count, dollars
end

return M
