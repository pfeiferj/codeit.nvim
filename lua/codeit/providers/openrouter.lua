local M = {}
local http = require('codeit.providers.http')
local chat = require('codeit.providers.protocols.chat')
local usage = require('codeit.providers.protocols.usage')
local models = require('codeit.providers.models')

function M.models(callback, options)
  local token = vim.env.OPENROUTER_API_KEY
  if not token or token == '' then return callback(nil, 'Set OPENROUTER_API_KEY to use OpenRouter') end
  local url = 'https://openrouter.ai/api/v1/models'
  if (options or {}).output_modalities == 'decisions' then url = url .. '?output_modalities=decisions' end
  http.get(url, { 'Authorization: Bearer ' .. token }, function(response, err, detail)
    if err then return callback(nil, err, detail) end
    callback(models.normalize('openrouter', response))
  end)
end

function M.chat(config, messages, tools, callback, on_text, active, on_activity)
  local key = vim.env.OPENROUTER_API_KEY
  if not key or key == '' then return callback(nil, 'Set OPENROUTER_API_KEY to use OpenRouter') end
  if active and not active() then return end
  local options = config.options or {}
  -- Response Healing repairs message text, not required tool-call arguments.
  local healing = options.response_healing == true and config.tool_choice ~= 'required'
  if healing then on_text = nil end
  local body = chat.body(config.model, messages, tools, on_text, config.tool_choice)
  if healing then
    body.response_format = { type = 'json_object' }
    body.plugins = { { id = 'response-healing' } }
  end
  if config.max_output_tokens then body.max_tokens = config.max_output_tokens end
  body.usage = { include = true }
  if options.routing_mode and options.routing_mode ~= '' then
    if options.routing_mode ~= 'auto' then body.provider = { sort = options.routing_mode } end
  else
    if options.preferred_provider and options.preferred_provider ~= '' then
      body.provider = { order = { options.preferred_provider } }
    end
  end
  if type(options.allow_fallbacks) == 'boolean' then
    body.provider = body.provider or {}
    body.provider.allow_fallbacks = options.allow_fallbacks
  end
  if options.service_tier and options.service_tier ~= '' then body.service_tier = options.service_tier end
  if options.effort and options.effort ~= '' then body.reasoning = { effort = options.effort } end
  http.post('https://openrouter.ai/api/v1/chat/completions', {
    'Content-Type: application/json', 'Authorization: Bearer ' .. key,
    'HTTP-Referer: https://github.com/codeit-nvim/codeit.nvim', 'X-Title: codeit.nvim',
  }, body, function(response, err, detail)
    if err then return callback(nil, err, nil, detail) end
    local message, failure, response_detail, truncated = chat.message(response, config.max_output_tokens)
    local billing
    if message then billing = usage.openrouter(response)
    elseif truncated then billing = response.usage end
    callback(message, failure, billing, response_detail)
  end, on_text and { responses = false, on_text = on_text, on_activity = on_activity } or nil, active)
end

--- Fetch model-specific OpenRouter upstream endpoints, including their pricing.
function M.endpoints(model, callback)
  local token = vim.env.OPENROUTER_API_KEY
  if not token or token == '' then return callback(nil, 'Set OPENROUTER_API_KEY to use OpenRouter') end
  if type(model) ~= 'string' then return callback(nil, 'Invalid OpenRouter model ID') end
  -- Routing variants share the base model's endpoint catalog.
  model = model:gsub(':nitro$', ''):gsub(':floor$', '')
  local author, slug = model:match('^([^/]+)/([^/]+)$')
  if not author then return callback(nil, 'OpenRouter model IDs must include author/model') end
  local function encode(value)
    return (value:gsub('[^%w%-%._~]', function(char) return string.format('%%%02X', char:byte()) end))
  end
  local url = 'https://openrouter.ai/api/v1/models/' .. encode(author) .. '/' .. encode(slug) .. '/endpoints'
  http.get(url, { 'Authorization: Bearer ' .. token }, function(response, err, detail)
    if err then return callback(nil, err, detail) end
    local entries = type(response.data) == 'table' and response.data.endpoints
    if type(entries) ~= 'table' or not vim.islist(entries) then
      return callback(nil, 'Invalid model endpoint catalog')
    end
    local endpoints = {}
    for _, entry in ipairs(entries) do
      if type(entry) == 'table' and type(entry.tag) == 'string' and entry.tag ~= ''
        and (entry.status == nil or entry.status == vim.NIL or tonumber(entry.status) == 0) then
        endpoints[#endpoints + 1] = entry
      end
    end
    table.sort(endpoints, function(a, b) return a.tag < b.tag end)
    callback(endpoints)
  end)
end

return M
