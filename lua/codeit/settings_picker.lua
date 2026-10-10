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
  draft.secondary_models = draft.secondary_models or {}
  draft.feature_settings = draft.feature_settings or {}
  local function valid() return not live or live() end
  local menu
  local function choose_model(secondary, feature, back)
    back = back or menu
    local selected = feature and settings.feature_config(draft, feature) or {
      provider = draft.provider, options = draft.request_options[draft.provider],
    }
    local models_setting = secondary and draft.secondary_models or draft.models
    vim.notify('codeit: loading ' .. selected.provider .. ' models…')
    providers.models(selected.provider, function(models, err)
      if not valid() then return end
      if err then vim.notify('codeit: ' .. err, vim.log.levels.ERROR); return back() end
      local search
      search = function()
        vim.ui.input({ prompt = 'Search models (ID, name, description; blank = all): ' }, function(query)
          if not valid() then return end
          if query == nil then return back() end
          local matches = M.search(models, query)
          if #matches == 0 then
            vim.notify('codeit: no matching models', vim.log.levels.INFO)
            return search()
          end
          vim.ui.select(matches, {
            prompt = selected.provider .. (secondary and ' secondary' or '') .. ' models (' .. #matches .. ' matches)',
            format_item = function(item)
              return item.id .. (item.name and ' — ' .. item.name or '')
            end,
          }, function(item)
            if not valid() then return end
            if item then
              if feature then draft.feature_settings[feature].model = item.id
              else models_setting[selected.provider] = item.id end
              return back()
            end
            search()
          end)
        end)
      end
      search()
    end, selected.options)
  end
  local function choose_upstream(options, model, back, inherit)
    model, back = model or draft.models.openrouter, back or menu
    vim.notify('codeit: loading upstream providers for ' .. model .. '…')
    providers.endpoints(model, function(endpoints, err)
      if not valid() then return end
      if err then vim.notify('codeit: could not load upstream providers: ' .. err, vim.log.levels.WARN) end
      local items = {
        { id = 'automatic', label = 'Automatic routing (clear preference)' },
        { id = 'manual', label = 'Enter provider slug manually' },
      }
      if inherit then table.insert(items, 1, { id = 'inherit', label = 'Inherit upstream preference' }) end
      for _, endpoint in ipairs(endpoints or {}) do
        items[#items + 1] = { id = 'endpoint', slug = endpoint.tag, label = M.endpoint_label(endpoint) }
      end
      if endpoints and #endpoints == 0 then vim.notify('codeit: no upstream endpoints listed for ' .. model) end
      vim.ui.select(items, { prompt = model .. ' upstream providers (USD; fallbacks remain enabled)',
        format_item = function(item) return item.label end }, function(item)
        if not valid() then return end
        if not item then return back() end
        if item.id == 'manual' then
          vim.ui.input({ prompt = 'Upstream provider slug (blank = automatic): ',
            default = options.preferred_provider or '' }, function(value)
            if not valid() then return end
            if value ~= nil then
              options.preferred_provider = vim.trim(value)
            end
            back()
          end)
        else
          options.preferred_provider = item.id == 'automatic' and '' or item.slug
          back()
        end
      end)
    end)
  end
  local function feature_menu(name)
    if not valid() then return end
    local feature = draft.feature_settings[name] or {}
    local selected = settings.feature_config(draft, name)
    local function back() feature_menu(name) end
    local function store()
      draft.feature_settings[name] = feature
      feature.options = feature.options or {}
      return feature.options
    end
    local function option_label(key)
      local value = (feature.options or {})[key]
      return value == nil and '(inherit)' or (value == '' and '(provider default)' or value)
    end
    local items = {
      { id = 'provider', label = 'Backend: ' .. (feature.provider ~= nil and feature.provider ~= ''
        and feature.provider or '(inherit: ' .. selected.provider .. ')') },
      { id = 'model', label = 'Search models: ' .. selected.model },
      { id = 'manual', label = 'Enter model ID manually' },
      { id = 'model_clear', label = 'Use inherited model' },
    }
    if selected.provider == 'openrouter' then
      for _, entry in ipairs({ { 'preferred_provider', 'Preferred upstream provider' },
        { 'service_tier', 'Service tier' }, { 'effort', 'Reasoning effort' } }) do
        items[#items + 1] = { id = entry[1], label = entry[2] .. ': ' .. option_label(entry[1]) }
      end
    else
      items[#items + 1] = { id = 'api_host', label = 'Copilot API host: ' .. option_label('api_host') }
    end
    vim.list_extend(items, {
      { id = 'options_clear', label = 'Inherit all request options' },
      { id = 'reset', label = 'Reset this feature to inherited settings' },
      { id = 'back', label = 'Back to settings' },
    })
    vim.ui.select(items, { prompt = settings.feature_labels[name],
      format_item = function(item) return item.label end }, function(item)
      if not valid() then return end
      if not item or item.id == 'back' then return menu() end
      local id = item.id
      if id == 'provider' then
        vim.ui.select({ '', 'openrouter', 'copilot' }, { prompt = 'Feature backend',
          format_item = function(value) return value == '' and '(inherit main backend)' or value end }, function(value)
          if not valid() then return end
          if value ~= nil then store(); feature.provider = value end
          back()
        end)
      elseif id == 'model' then
        store()
        choose_model(false, name, back)
      elseif id == 'manual' then
        vim.ui.input({ prompt = 'Feature model ID (blank = inherit): ', default = feature.model or '' }, function(value)
          if not valid() then return end
          if value ~= nil then store(); feature.model = vim.trim(value) end
          back()
        end)
      elseif id == 'model_clear' then
        store(); feature.model = nil; back()
      elseif id == 'reset' then
        draft.feature_settings[name] = nil; back()
      elseif id == 'options_clear' then
        store(); feature.options = nil; back()
      elseif id == 'preferred_provider' then
        choose_upstream(store(), selected.model, back, true)
      else
        local values = id == 'api_host' and settings.copilot_hosts
          or (id == 'service_tier' and settings.tiers or settings.efforts)
        local choices = { { value = nil, label = '(inherit)' } }
        for _, value in ipairs(values) do
          choices[#choices + 1] = { value = value, label = value == '' and '(provider default)' or value }
        end
        vim.ui.select(choices, { prompt = id, format_item = function(choice) return choice.label end }, function(choice)
          if not valid() then return end
          if choice then store()[id] = choice.value end
          back()
        end)
      end
    end)
  end
  menu = function()
    if not valid() then return end
    local options = draft.request_options[draft.provider] or {}
    local secondary_model = draft.secondary_models[draft.provider]
    local items = {
      { id = 'provider', label = 'Backend: ' .. draft.provider },
      { id = 'model', label = 'Search models: ' .. draft.models[draft.provider] },
      { id = 'manual', label = 'Enter model ID manually' },
      { id = 'secondary_model', label = 'Search fallback secondary models (legacy): '
        .. (secondary_model and secondary_model ~= '' and secondary_model or '(main model)') },
      { id = 'secondary_manual', label = 'Enter fallback secondary model ID manually' },
      { id = 'secondary_clear', label = 'Use main model as feature fallback' },
    }
    for _, name in ipairs(settings.features) do
      local selected = settings.feature_config(draft, name)
      items[#items + 1] = { id = name, label = settings.feature_labels[name] .. ': '
        .. selected.provider .. ' / ' .. selected.model }
    end
    if draft.provider == 'openrouter' then
      vim.list_extend(items, {
        { id = 'preferred_provider', label = 'Preferred upstream provider: ' .. (options.preferred_provider or '') },
        { id = 'service_tier', label = 'Service tier: ' .. (options.service_tier or '') },
        { id = 'effort', label = 'Reasoning effort: ' .. (options.effort or '') },
      })
    elseif draft.provider == 'copilot' then
      items[#items + 1] = { id = 'api_host', label = 'Copilot API host: '
        .. (options.api_host and options.api_host ~= '' and options.api_host or 'api.githubcopilot.com (default)') }
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
      elseif id == 'model' or id == 'secondary_model' then
        choose_model(id == 'secondary_model')
      elseif id == 'secondary_clear' then
        draft.secondary_models[draft.provider] = ''
        menu()
      elseif vim.tbl_contains(settings.features, id) then
        feature_menu(id)
      elseif id == 'preferred_provider' then
        draft.request_options.openrouter = options
        choose_upstream(options)
      elseif id == 'manual' or id == 'secondary_manual' then
        local secondary = id == 'secondary_manual'
        local models_setting = secondary and draft.secondary_models or draft.models
        vim.ui.input({ prompt = secondary and 'Secondary model ID (blank = main model): ' or 'Model ID: ',
          default = models_setting[draft.provider] or '' }, function(value)
          if not valid() then return end
          if value ~= nil and (secondary or vim.trim(value) ~= '') then
            models_setting[draft.provider] = vim.trim(value)
          end
          menu()
        end)
      elseif id == 'api_host' then
        vim.ui.select(settings.copilot_hosts, {
          prompt = 'Copilot API host',
          format_item = function(value) return value == '' and 'api.githubcopilot.com (default)' or value end,
        }, function(value)
          if not valid() then return end
          if value ~= nil then options.api_host = value; draft.request_options.copilot = options end
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
