local M = {}
local auth = require('codeit.providers.codex.auth')
local http = require('codeit.providers.http')
local responses = require('codeit.providers.protocols.responses')
local usage = require('codeit.providers.protocols.usage')
local models = require('codeit.providers.models')
local subscription_usage = require('codeit.providers.codex.usage')

function M.models(callback)
  local credentials, err = auth.credentials()
  if not credentials then return callback(nil, err) end
  local headers = auth.headers(credentials)
  headers[#headers + 1] = 'Authorization: Bearer ' .. credentials.token
  http.get(auth.url .. '/models?client_version=' .. auth.client_version, headers, function(response, failure, detail)
    if failure then return callback(nil, auth.redact(failure, credentials), auth.redact(detail, credentials)) end
    callback(models.normalize('codex', response))
  end)
end

function M.chat(config, messages, tools, callback, on_text, active, on_activity)
  local credentials, err = auth.credentials()
  if not credentials then return callback(nil, err) end
  if active and not active() then return end
  local body, invalid = responses.body(config.model, messages, tools, 'Codex')
  if invalid then return callback(nil, invalid) end
  local input, instructions = {}, {}
  for _, item in ipairs(body.input) do
    if item.role == 'system' then
      if type(item.content) == 'string' then instructions[#instructions + 1] = item.content
      else
        for _, part in ipairs(item.content) do instructions[#instructions + 1] = part.text end
      end
    else input[#input + 1] = item end
  end
  body.input, body.instructions = input, table.concat(instructions, '\n\n')
  -- The subscription backend requires SSE and rejects max_output_tokens.
  body.stream = true
  local headers = { 'Content-Type: application/json', 'Authorization: Bearer ' .. credentials.token }
  vim.list_extend(headers, auth.headers(credentials))
  headers[#headers + 1] = 'Accept: text/event-stream'
  local options = config.options or {}
  if options.effort and options.effort ~= '' then body.reasoning = { effort = options.effort } end
  local rate_limits = {}
  http.post(auth.url .. '/responses', headers, body, function(response, failure, detail, response_headers)
    local billing = usage.codex(response)
    local subscription = vim.tbl_extend('force', subscription_usage.parse(response_headers) or {}, rate_limits)
    if next(subscription) then
      billing = billing or {}
      billing.codex_subscription = subscription
    end
    if failure then return callback(nil, auth.redact(failure, credentials), billing, auth.redact(detail, credentials)) end
    local message, response_error = responses.message(response, 'Codex')
    local response_detail = response_error and vim.json.encode(response) or nil
    callback(message, auth.redact(response_error, credentials), billing, auth.redact(response_detail, credentials))
  end, { responses = true, on_text = on_text or function() end, on_activity = on_activity,
    on_codex_usage = function(event)
      rate_limits = vim.tbl_extend('force', rate_limits, subscription_usage.parse(nil, event) or {})
    end }, active)
end

return M
