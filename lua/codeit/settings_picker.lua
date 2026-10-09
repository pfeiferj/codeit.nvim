local M = {}
local providers = require('codeit.providers')
local settings = require('codeit.settings')

-- Explicit filtering works with stock vim.ui and enhanced UI plugins alike.
function M.search(models, query)
  local matches = {}
  query = query:lower()
  for _, model in ipairs(models) do
    local text = (model.id .. ' ' .. (model.name or '') .. ' ' .. (model.description or '')):lower()
    local match = true
    for word in query:gmatch('%S+') do
      if not text:find(word, 1, true) then match = false; break end
    end
    if match then matches[#matches + 1] = model end
  end
  return matches
end

local function price(value, multiplier)
  local number = (type(value) == 'string' or type(value) == 'number') and tonumber(value)
  if not number or number < 0 or number == math.huge or number ~= number then return 'unknown' end
  return '$' .. string.format('%.6f', number * multiplier):gsub('0+$', ''):gsub('%.$', '')
end

function M.endpoint_label(endpoint)
  local pricing = type(endpoint.pricing) == 'table' and endpoint.pricing or {}
  local name = type(endpoint.provider_name) == 'string' and endpoint.provider_name or endpoint.tag
  local label = name .. ' [' .. endpoint.tag .. ']'
    .. ' — input ' .. price(pricing.prompt, 1000000) .. ', output ' .. price(pricing.completion, 1000000)
    .. ' / 1M tokens'
  if pricing.request ~= nil and pricing.request ~= vim.NIL and tonumber(pricing.request) ~= 0 then
    label = label .. '; ' .. price(pricing.request, 1) .. ' / request'
  end
  if type(endpoint.quantization) == 'string' then label = label .. ' (' .. endpoint.quantization .. ')' end
  return label
end

function M.show(current, apply, live)
  local draft = vim.deepcopy(current)
  local function valid() return not live or live() end
  local menu
  local function choose_model()
    vim.notify('codeit: loading ' .. draft.provider .. ' models…')
    providers.models(draft.provider, function(models, err)
      if not valid() then return end
      if err then vim.notify('codeit: ' .. err, vim.log.levels.ERROR); return menu() end
      local search
      search = function()
        vim.ui.input({ prompt = 'Search models (ID, name, description; blank = all): ' }, function(query)
          if not valid() then return end
          if query == nil then return menu() end
          local matches = M.search(models, query)
          if #matches == 0 then
            vim.notify('codeit: no matching models', vim.log.levels.INFO)
            return search()
          end
          vim.ui.select(matches, {
            prompt = draft.provider .. ' models (' .. #matches .. ' matches)',
            format_item = function(item)
              return item.id .. (item.name and ' — ' .. item.name or '')
            end,
          }, function(item)
            if not valid() then return end
            if item then draft.models[draft.provider] = item.id; return menu() end
            search()
          end)
        end)
      end
      search()
    end)
  end
  local function choose_upstream(options)
    local model = draft.models.openrouter
    vim.notify('codeit: loading upstream providers for ' .. model .. '…')
    providers.endpoints(model, function(endpoints, err)
      if not valid() then return end
      if err then vim.notify('codeit: could not load upstream providers: ' .. err, vim.log.levels.WARN) end
      local items = {
        { id = 'automatic', label = 'Automatic routing (clear preference)' },
        { id = 'manual', label = 'Enter provider slug manually' },
      }
      for _, endpoint in ipairs(endpoints or {}) do
        items[#items + 1] = { id = 'endpoint', slug = endpoint.tag, label = M.endpoint_label(endpoint) }
      end
      if endpoints and #endpoints == 0 then vim.notify('codeit: no upstream endpoints listed for ' .. model) end
      vim.ui.select(items, { prompt = model .. ' upstream providers (USD; fallbacks remain enabled)',
        format_item = function(item) return item.label end }, function(item)
        if not valid() then return end
        if not item then return menu() end
        if item.id == 'manual' then
          vim.ui.input({ prompt = 'Upstream provider slug (blank = automatic): ',
            default = options.preferred_provider or '' }, function(value)
            if not valid() then return end
            if value ~= nil then
              options.preferred_provider = vim.trim(value)
              draft.request_options.openrouter = options
            end
            menu()
          end)
        else
          options.preferred_provider = item.id == 'automatic' and '' or item.slug
          draft.request_options.openrouter = options
          menu()
        end
      end)
    end)
  end
  menu = function()
    if not valid() then return end
    local options = draft.request_options.openrouter or {}
    local items = {
      { id = 'provider', label = 'Backend: ' .. draft.provider },
      { id = 'model', label = 'Search models: ' .. draft.models[draft.provider] },
      { id = 'manual', label = 'Enter model ID manually' },
    }
    if draft.provider == 'openrouter' then
      vim.list_extend(items, {
        { id = 'preferred_provider', label = 'Preferred upstream provider: ' .. (options.preferred_provider or '') },
        { id = 'service_tier', label = 'Service tier: ' .. (options.service_tier or '') },
        { id = 'effort', label = 'Reasoning effort: ' .. (options.effort or '') },
      })
    end
    vim.list_extend(items, {
      { id = 'session', label = 'Apply for this session' },
      { id = 'global', label = 'Apply and save globally' },
      { id = 'workspace', label = 'Apply and save for this workspace' },
    })
    vim.ui.select(items, { prompt = 'Codeit settings (cancel to discard)',
      format_item = function(item) return item.label end }, function(item)
      if not item or not valid() then return end
      local id = item.id
      if id == 'provider' then
        vim.ui.select({ 'openrouter', 'copilot' }, { prompt = 'Backend' }, function(provider)
          if not valid() then return end
          if provider then draft.provider = provider end
          menu()
        end)
      elseif id == 'model' then
        choose_model()
      elseif id == 'preferred_provider' then
        choose_upstream(options)
      elseif id == 'manual' then
        vim.ui.input({ prompt = 'Model ID: ', default = draft.models[draft.provider] }, function(value)
          if not valid() then return end
          if value ~= nil and vim.trim(value) ~= '' then draft.models[draft.provider] = vim.trim(value) end
          menu()
        end)
      elseif id == 'service_tier' or id == 'effort' then
        vim.ui.select(id == 'service_tier' and settings.tiers or settings.efforts, {
          prompt = id == 'service_tier' and 'Service tier (model/provider dependent)' or 'Reasoning effort (model dependent)',
          format_item = function(value) return value == '' and '(provider default)' or value end,
        }, function(value)
          if not valid() then return end
          if value ~= nil then options[id] = value; draft.request_options.openrouter = options end
          menu()
        end)
      else
        apply(draft, id)
      end
    end)
  end
  menu()
end

return M
