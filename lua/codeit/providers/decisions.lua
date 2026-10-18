local M = {}
local http = require('codeit.providers.http')

function M.url(provider, options)
  local url = (options or {}).base_url
  if provider == 'openrouter' then return 'https://openrouter.ai/api/alpha/decisions' end
  if url == nil or url == '' then
    if provider == 'typesafe' then url = 'https://api.typesafe.ai/v1'
    else return nil, 'Set a base_url for the generic decisions provider' end
  end
  if type(url) ~= 'string' or not url:match('^https?://[^/]+') or url:find('[%s%c?#@]') then
    return nil, 'Invalid decisions base URL'
  end
  return url:gsub('/+$', '') .. '/systemone'
end

function M.evaluate(config, state, questions, callback, active)
  if active and not active() then return end
  local provider, options = config.provider, config.options or {}
  if not vim.tbl_contains({ 'typesafe', 'decisions', 'openrouter' }, provider) then
    return callback(nil, 'Decisions assessments require typesafe, decisions, or openrouter')
  end
  local url, err = M.url(provider, options)
  if not url then return callback(nil, err) end
  local env = provider == 'openrouter' and 'OPENROUTER_API_KEY' or options.api_key_env
  if env == nil then env = provider == 'typesafe' and 'TYPESAFE_API_KEY' or '' end
  if type(env) ~= 'string' or (env ~= '' and not env:match('^[%a_][%w_]*$')) then
    return callback(nil, 'Invalid API key environment variable')
  end
  local key = env ~= '' and vim.env[env] or nil
  if provider ~= 'decisions' and (not key or key == '') then
    return callback(nil, 'Set ' .. (env ~= '' and env or 'an API key environment variable') .. ' to use ' .. provider)
  end
  local headers = { 'Content-Type: application/json' }
  if key and key ~= '' then
    if key:find('%c') then return callback(nil, 'Invalid API key: contains control characters') end
    headers[#headers + 1] = 'Authorization: Bearer ' .. key
  end
  local body = { model = config.model, state = state, questions = questions }
  if provider == 'openrouter' then
    headers[#headers + 1] = 'HTTP-Referer: https://github.com/codeit-nvim/codeit.nvim'
    headers[#headers + 1] = 'X-Title: codeit.nvim'
    if options.routing_mode and options.routing_mode ~= '' then
      if options.routing_mode ~= 'auto' then body.provider = { sort = options.routing_mode } end
    elseif options.preferred_provider and options.preferred_provider ~= '' then
      body.provider = { order = { options.preferred_provider } }
    end
    if type(options.allow_fallbacks) == 'boolean' then
      body.provider = body.provider or {}
      body.provider.allow_fallbacks = options.allow_fallbacks
    end
  end
  http.post(url, headers, body, function(response, failure, detail)
    if active and not active() then return end
    if failure then return callback(nil, failure, nil, detail) end
    if type(response) ~= 'table' or type(response.answers) ~= 'table' then
      return callback(nil, 'Invalid decisions response')
    end
    local usage = type(response.usage) == 'table' and response.usage or {}
    callback(response.answers, nil, { prompt_tokens = usage.input_tokens,
      completion_tokens = usage.output_tokens, cost = usage.cost })
  end, nil, active)
end

return M
