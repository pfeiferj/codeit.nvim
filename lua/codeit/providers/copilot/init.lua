local M = {}
local http = require('codeit.providers.http')
local auth = require('codeit.providers.copilot.auth')
local chat = require('codeit.providers.protocols.chat')
local responses = require('codeit.providers.protocols.responses')
local usage = require('codeit.providers.protocols.usage')
local models = require('codeit.providers.models')
local catalogs = {}

local function headers(token)
  return {
    'Authorization: Bearer ' .. token,
    -- The versioned catalog exposes billing.token_prices.
    'X-GitHub-Api-Version: 2026-08-01',
    'Editor-Version: Neovim/0.12.0',
    'Editor-Plugin-Version: codeit.nvim/0.1.0',
    'Copilot-Integration-Id: vscode-chat',
    'Openai-Intent: conversation-panel',
  }
end

function M.url(options)
  local host = options and options.api_host
  if host == nil or host == '' then host = 'api.githubcopilot.com' end
  -- Restrict destinations so a typo cannot send a Copilot bearer token to an arbitrary host.
  if not vim.tbl_contains(require('codeit.settings').copilot_hosts, host) then
    return nil, 'Invalid Copilot API host: ' .. tostring(host)
  end
  return 'https://' .. host
end

local function copilot_endpoint(model)
  local endpoints = model and model.supported_endpoints
  -- Older catalogs do not report endpoints; retain their chat-completions behavior.
  if endpoints == nil or endpoints == vim.NIL then return '/chat/completions' end
  if type(endpoints) == 'table' then
    if vim.tbl_contains(endpoints, '/chat/completions') then return '/chat/completions' end
    if vim.tbl_contains(endpoints, '/responses') then return '/responses' end
  end
  return nil, 'Copilot model ' .. tostring(model.id)
    .. ' does not advertise a supported chat endpoint (/chat/completions or /responses); choose another model'
end

function M.models(callback, options)
  local url, url_error = M.url(options)
  if not url then return callback(nil, url_error) end
  auth.token(function(token, err)
    if err then return callback(nil, err) end
    http.get(url .. '/models', headers(token), function(response, failure, detail)
      if failure then return callback(nil, failure, detail) end
      local entries, invalid = models.normalize('copilot', response)
      if not entries then return callback(nil, invalid) end
      local catalog = {}
      for _, model in ipairs(entries) do catalog[model.id] = model end
      catalogs[url] = catalog
      callback(entries)
    end)
  end)
end

function M.chat(config, messages, tools, callback, on_text, active, on_activity)
  local url, url_error = M.url(config.options)
  if not url then return callback(nil, url_error) end
  local function route()
    local endpoint, endpoint_error = copilot_endpoint(catalogs[url][config.model])
    if not endpoint then return callback(nil, endpoint_error) end
    auth.token(function(token, err)
      if err then return callback(nil, err) end
      if active and not active() then return end
      local body, invalid
      if endpoint == '/responses' then
        body, invalid = responses.body(config.model, messages, tools)
        if invalid then return callback(nil, invalid) end
        if config.max_output_tokens then body.max_output_tokens = config.max_output_tokens end
        if on_text then body.stream = true end
      else
        body = chat.body(config.model, messages, tools, on_text)
        if config.max_output_tokens then body.max_completion_tokens = config.max_output_tokens end
      end
      local options = config.options or {}
      if options.effort and options.effort ~= '' then
        if endpoint == '/responses' then body.reasoning = { effort = options.effort }
        else body.reasoning_effort = options.effort end
      end
      local request_headers = { 'Content-Type: application/json' }
      vim.list_extend(request_headers, headers(token))
      http.post(url .. endpoint, request_headers, body, function(response, failure, detail)
        if failure then return callback(nil, failure, nil, detail) end
        local message, response_error, response_detail
        local billing
        if endpoint == '/responses' then
          message, response_error = responses.message(response)
          billing = (not response_error or config.max_output_tokens) and usage.copilot(response) or nil
          response_detail = response_error and vim.json.encode(response) or nil
        else
          local truncated
          message, response_error, response_detail, truncated = chat.message(response, config.max_output_tokens)
          if message or truncated then billing = usage.copilot(response) end
        end
        callback(message, response_error, billing, response_detail)
      end, on_text and { responses = endpoint == '/responses', on_text = on_text, on_activity = on_activity } or nil, active)
    end)
  end
  if catalogs[url] then return route() end
  -- Manual model IDs and secondary tasks also need endpoint metadata, not just the picker.
  M.models(function(_, err, detail)
    if err then return callback(nil, err, nil, detail) end
    route()
  end, config.options)
end

return M
