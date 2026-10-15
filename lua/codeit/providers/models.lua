local M = {}
local limits, pending = {}, {}

function M.normalize(provider, response)
  local entries = response.data or response.models or response
  if type(entries) ~= 'table' or not vim.islist(entries) then
    return nil, 'Invalid model catalog'
  end
  local models = {}
  for _, entry in ipairs(entries) do
    if provider == 'codex' and type(entry) == 'table' and type(entry.slug) == 'string' then
      entry = vim.tbl_extend('force', {}, entry, { id = entry.slug, name = entry.display_name,
        context_length = entry.context_window })
    end
    if type(entry) == 'table' and type(entry.id) == 'string' then models[#models + 1] = entry end
  end
  table.sort(models, function(a, b) return a.id < b.id end)
  return models
end

--- Resolve a model's context window; failures are cached for this session.
function M.context_limit(config, callback, fetch_models)
  local key = config.provider .. '/' .. config.model
  if config.provider == 'copilot' then
    local url, err = require('codeit.providers.copilot').url(config.options)
    if not url then return callback(nil, err) end
    key = key .. '/' .. url
  end
  if config.provider == 'openai' then
    local url, err = require('codeit.providers.openai').url(config.options)
    if not url then return callback(nil, err) end
    key = key .. '/' .. url
  end
  if limits[key] ~= nil then return callback(limits[key] or nil) end
  if pending[key] then
    pending[key][#pending[key] + 1] = callback
    return
  end
  pending[key] = { callback }
  local function finish(limit, err, detail)
    if type(limit) ~= 'number' or limit <= 0 or limit == math.huge or limit ~= limit then
      limit = nil
      err = err or ('no context limit reported for ' .. config.model)
    end
    if err then require('codeit.providers.log').error(config, err, detail) end
    limits[key] = limit or false
    local callbacks = pending[key]
    pending[key] = nil
    for _, done in ipairs(callbacks) do done(limit, err) end
  end
  local function extract(response)
    local models = response.data or response.models or response
    if type(models) ~= 'table' then return finish(nil) end
    for _, entry in ipairs(models) do
      if type(entry) == 'table' and entry.id == config.model then
        if config.provider == 'openrouter' or config.provider == 'codex' or config.provider == 'openai' then
          return finish(tonumber(entry.context_length))
        end
        local limits_data = type(entry.capabilities) == 'table' and entry.capabilities.limits or nil
        if type(limits_data) == 'table' then
          return finish(tonumber(limits_data.max_context_window_tokens or limits_data.max_prompt_tokens))
        end
        return finish(nil)
      end
    end
    finish(nil, 'model not found in provider metadata: ' .. config.model)
  end
  fetch_models(config.provider, function(models, err, detail)
    if err then return finish(nil, err, detail) end
    extract(models)
  end, config.options)
end

return M
