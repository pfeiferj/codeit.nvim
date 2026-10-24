local M = {}
local http = require('codeit.providers.http')
local chat = require('codeit.providers.protocols.chat')
local usage = require('codeit.providers.protocols.usage')
local models = require('codeit.providers.models')

function M.url(options)
  local url = (options or {}).base_url
  if url == nil or url == '' then url = 'https://api.openai.com/v1' end
  if type(url) ~= 'string' or not url:match('^https?://[^/]+')
    or url:find('[%s%c?#@]') then return nil, 'Invalid OpenAI-compatible base URL' end
  return (url:gsub('/+$', ''))
end

local function destination(options)
  options = options or {}
  local url, err = M.url(options)
  if not url then return nil, nil, err end
  local env = options.api_key_env
  if env == nil then env = 'OPENAI_API_KEY' end
  if type(env) ~= 'string' or (env ~= '' and not env:match('^[%a_][%w_]*$')) then
    return nil, nil, 'Invalid API key environment variable'
  end
  local headers = { 'Content-Type: application/json' }
  local key = env ~= '' and vim.env[env] or nil
  if key and key ~= '' then
    if key:find('%c') then return nil, nil, 'Invalid API key: contains control characters' end
    headers[#headers + 1] = 'Authorization: Bearer ' .. key
  end
  return url, headers
end

function M.models(callback, options)
  local url, headers, err = destination(options)
  if err then return callback(nil, err) end
  http.get(url .. '/models', headers, function(response, failure, detail)
    if failure then return callback(nil, failure, detail) end
    callback(models.normalize('openai', response))
  end)
end

function M.chat(config, messages, tools, callback, on_text, active, on_activity)
  if active and not active() then return end
  local url, headers, err = destination(config.options)
  if err then return callback(nil, err) end
  local body = chat.body(config.model, messages, tools, on_text, config.tool_choice)
  if config.max_output_tokens then body.max_tokens = config.max_output_tokens end
  http.post(url .. '/chat/completions', headers, body, function(response, failure, detail)
    if failure then return callback(nil, failure, nil, detail) end
    local message, message_error, response_detail, truncated = chat.message(response, config.max_output_tokens)
    local billing
    if message or truncated then billing = usage.openrouter(response) end
    callback(message, message_error, billing, response_detail)
  end, on_text and { responses = false, on_text = on_text, on_activity = on_activity } or nil, active)
end

return M
