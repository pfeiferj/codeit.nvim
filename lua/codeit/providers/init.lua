local M = {}
local models = require('codeit.providers.models')
local log = require('codeit.providers.log')
local backends = {
  openrouter = 'codeit.providers.openrouter',
  copilot = 'codeit.providers.copilot',
  codex = 'codeit.providers.codex',
  openai = 'codeit.providers.openai',
}

local function backend(provider)
  local name = backends[provider]
  if name then return require(name) end
end

--- Fetch available models from the selected backend (no completion request).
--- Optional options uses the same per-provider request options as chat.
function M.models(provider, callback, options)
  if provider == 'typesafe' then return callback({ { id = 'jev-latest', name = 'Jev (latest)' } }) end
  if provider == 'decisions' then return callback({}, nil) end
  local implementation = backend(provider)
  if not implementation then return callback(nil, 'Unknown provider: ' .. tostring(provider)) end
  implementation.models(callback, options)
end

--- Evaluate typed decisions questions without requesting generated text.
function M.decisions(config, state, questions, callback, active)
  require('codeit.providers.decisions').evaluate(config, state, questions, function(answers, err, usage, detail)
    if err then log.error(config, err, detail) end
    callback(answers, err, usage)
  end, active)
end

--- Fetch model-specific OpenRouter upstream endpoints, including their pricing.
function M.endpoints(model, callback)
  require('codeit.providers.openrouter').endpoints(model, callback)
end

--- Resolve a model's context window; failures are cached for this session.
function M.context_limit(config, callback)
  models.context_limit(config, callback, M.models)
end

--- Send a chat request, normalizing provider responses. callback(message, error, usage).
function M.chat(config, messages, tools, callback, on_text, active, on_activity)
  local implementation = backend(config.provider)
  local retried, displayed, finished = false, false, false
  local send
  local function preview(text)
    if finished or (active and not active()) then return end
    if type(text) == 'string' and text ~= '' then displayed = true end
    on_text(text)
  end
  local function finish(message, err, usage, detail)
    if finished or (active and not active()) then return end
    if err then log.error(config, err, detail) end
    -- Retry only this request, before the caller can retain or execute tool calls.
    -- Never replace text the user has already seen with a second generation.
    if not message and err == 'Response has no assistant message' and not retried and not displayed then
      retried = true
      return vim.defer_fn(send, 1000)
    end
    finished = true
    callback(message, err, usage)
  end
  if not implementation then return finish(nil, 'Unknown provider: ' .. tostring(config.provider)) end
  send = function()
    if finished or (active and not active()) then return end
    implementation.chat(config, messages, tools, finish, on_text and preview or nil, active, on_activity)
  end
  send()
end

return M
