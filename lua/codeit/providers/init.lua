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
  local implementation = backend(provider)
  if not implementation then return callback(nil, 'Unknown provider: ' .. tostring(provider)) end
  implementation.models(callback, options)
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
  local function finish(message, err, usage, detail)
    if active and not active() then return end
    if err then log.error(config, err, detail) end
    callback(message, err, usage)
  end
  local implementation = backend(config.provider)
  if not implementation then return finish(nil, 'Unknown provider: ' .. tostring(config.provider)) end
  implementation.chat(config, messages, tools, finish, on_text, active, on_activity)
end

return M
