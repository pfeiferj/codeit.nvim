local M = {}

function M.cached_tokens(usage)
  if not usage then return nil end
  local details = usage.prompt_tokens_details or usage.input_tokens_details
  return type(details) == 'table' and details.cached_tokens or nil
end

-- Normalize Copilot's two token-usage formats and server-reported charge.
-- Keep cost in USD like OpenRouter: 1e9 nano-AIU = 1 credit = $0.01.
function M.copilot(response)
  local usage = type(response.usage) == 'table' and response.usage or nil
  local billing = type(response.copilot_usage) == 'table' and response.copilot_usage or nil
  if not usage and not billing then return nil end
  local nano = billing and billing.total_nano_aiu
  nano = (type(nano) == 'number' or type(nano) == 'string') and tonumber(nano) or nil
  return {
    cost = nano and nano >= 0 and nano < math.huge and nano / 100000000000 or nil,
    prompt_tokens = usage and (usage.prompt_tokens or usage.input_tokens),
    completion_tokens = usage and (usage.completion_tokens or usage.output_tokens),
    total_tokens = usage and usage.total_tokens,
    cached_tokens = M.cached_tokens(usage),
  }
end

function M.openrouter(response)
  local usage = type(response.usage) == 'table' and response.usage or nil
  return {
    cost = usage and usage.cost,
    prompt_tokens = usage and usage.prompt_tokens,
    completion_tokens = usage and usage.completion_tokens,
    total_tokens = usage and usage.total_tokens,
    cached_tokens = M.cached_tokens(usage),
  }
end

function M.codex(response)
  local raw = type(response) == 'table' and type(response.usage) == 'table' and response.usage or nil
  return raw and { prompt_tokens = raw.input_tokens, completion_tokens = raw.output_tokens,
    total_tokens = raw.total_tokens, cached_tokens = M.cached_tokens(raw) } or nil
end

return M
