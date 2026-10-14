local M = {}
local providers = require('codeit.providers')
local settings = require('codeit.settings')
local settings_menu = require('codeit.settings.menu')

local catalog = require('codeit.settings.catalog')
M.search = catalog.search
M.endpoint_label = catalog.endpoint_label

local function routing_label(value)
  return ({ [''] = 'Use preferred provider', auto = 'Automatic routing',
    price = 'Lowest price', latency = 'Lowest latency', throughput = 'Highest throughput' })[value or '']
end

local function fallback_label(value)
  if value == true then return 'Enabled' end
  if value == false then return 'Disabled' end
  return '(provider default)'
end

function M.show(current, apply, live)
  local draft = vim.deepcopy(current)
  draft.feature_settings = draft.feature_settings or {}
  draft.model_presets = draft.model_presets or {}
  local function valid() return not live or live() end
  local menu
  local positions = {}
  local function select(items, opts, callback)
    opts.selected = positions[opts.prompt]
    return settings_menu.select(items, opts, function(item, index)
      if index then positions[opts.prompt] = index end
      callback(item)
    end)
  end
  local function choose_model(feature, back, preset)
    back = back or menu
    local selected = feature and (preset and settings.preset_config(draft, feature)
      or settings.feature_config(draft, feature)) or {
      provider = draft.provider, options = draft.request_options[draft.provider],
    }
    vim.notify('codeit: loading ' .. selected.provider .. ' models…')
    providers.models(selected.provider, function(models, err)
      if not valid() then return end
      if err then vim.notify('codeit: ' .. err, vim.log.levels.ERROR); return back() end
      local choices = vim.list_extend({}, models)
      table.sort(choices, function(a, b) return a.id < b.id end)
      select(choices, {
        prompt = selected.provider .. ' models',
        format_item = function(item)
          return item.id .. (item.name and ' — ' .. item.name or '')
            .. (item.description and ' — ' .. item.description or '')
        end,
      }, function(item)
        if not valid() then return end
        if item then
          if feature then
            local entries = preset and draft.model_presets or draft.feature_settings
            entries[feature].model = item.id
          else draft.models[selected.provider] = item.id end
        end
        back()
      end)
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
      select(items, { prompt = model .. ' upstream providers (USD; fallbacks remain enabled)',
        format_item = function(item) return item.label end }, function(item)
        if not valid() then return end
        if not item then return back() end
        if item.id == 'manual' then
          require('codeit.ui.input').show({ prompt = 'Upstream provider slug (blank = automatic): ',
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
  local function override_menu(name, preset)
    if not valid() then return end
    local entries = preset and draft.model_presets or draft.feature_settings
    local feature = entries[name] or {}
    local selected = preset and settings.preset_config(draft, name) or settings.feature_config(draft, name)
    local title = preset and ('Preset: ' .. settings.preset_labels[name]) or settings.feature_labels[name]
    local function back() override_menu(name, preset) end
    local function store()
      entries[name] = feature
      feature.options = feature.options or {}
      return feature.options
    end
    local function option_label(key)
      local value = (feature.options or {})[key]
      if key == 'routing_mode' and value ~= nil then return routing_label(value) end
      if key == 'allow_fallbacks' and value ~= nil then return fallback_label(value) end
      return value == nil and '(inherit)' or (value == '' and '(provider default)' or value)
    end
    local items = {
      { id = 'provider', label = 'Backend: ' .. (feature.provider ~= nil and feature.provider ~= ''
        and feature.provider or '(inherit: ' .. selected.provider .. ')') },
      { id = 'model', label = 'Browse models: ' .. selected.model },
      { id = 'manual', label = 'Enter model ID manually' },
    }
    if not preset then
      local assigned = settings.feature_preset(draft, name)
      table.insert(items, 1, { id = 'preset', label = 'Preset: '
        .. (settings.preset_labels[assigned] or '(main settings only)')
        .. (feature.preset == nil and ' (default)' or '') })
    end
    if selected.provider == 'openrouter' then
      for _, entry in ipairs({ { 'routing_mode', 'Routing mode' }, { 'preferred_provider', 'Preferred upstream provider' },
        { 'allow_fallbacks', 'Provider fallback' }, { 'service_tier', 'Service tier' }, { 'effort', 'Reasoning effort' } }) do
        items[#items + 1] = { id = entry[1], label = entry[2] .. ': ' .. option_label(entry[1]) }
      end
    elseif selected.provider == 'codex' then
      items[#items + 1] = { id = 'effort', label = 'Reasoning effort: ' .. option_label('effort') }
    else
      items[#items + 1] = { id = 'api_host', label = 'Copilot API host: ' .. option_label('api_host') }
      items[#items + 1] = { id = 'effort', label = 'Reasoning effort: ' .. option_label('effort') }
    end
    vim.list_extend(items, {
      { id = 'model_clear', label = 'Use inherited model' },
      { id = 'options_clear', label = 'Inherit all request options' },
      { id = 'reset', label = preset and 'Reset preset to main chat settings' or 'Reset feature to its default preset' },
      { id = 'back', label = 'Back to settings' },
    })
    for _, item in ipairs(items) do
      item.section = (item.id == 'preset' or item.id == 'provider' or item.id == 'model' or item.id == 'manual')
        and 'Model selection'
        or ((item.id == 'routing_mode' or item.id == 'preferred_provider' or item.id == 'service_tier'
          or item.id == 'allow_fallbacks' or item.id == 'effort' or item.id == 'api_host')
          and 'Request options' or 'Inheritance and navigation')
    end
    select(items, { prompt = title,
      format_item = function(item) return item.label end }, function(item)
      if not valid() then return end
      if not item or item.id == 'back' then return menu() end
      local id = item.id
      if id == 'preset' then
        local choices = {
          { id = 'default', label = 'Default (' .. settings.preset_labels[settings.feature_presets[name]] .. ')' },
          { id = '', label = 'Main settings only (no preset)' },
        }
        for _, value in ipairs(settings.presets) do
          choices[#choices + 1] = { id = value, label = settings.preset_labels[value] }
        end
        select(choices, { prompt = 'Feature preset', format_item = function(choice) return choice.label end }, function(choice)
          if not valid() then return end
          if choice then
            store()
            feature.preset = choice.id ~= 'default' and choice.id or nil
          end
          back()
        end)
      elseif id == 'provider' then
        select({ '', 'openrouter', 'copilot', 'codex' }, { prompt = title .. ' backend',
          format_item = function(value) return value == '' and '(inherit backend)' or value end }, function(value)
          if not valid() then return end
          if value ~= nil then store(); feature.provider = value end
          back()
        end)
      elseif id == 'model' then
        store()
        choose_model(name, back, preset)
      elseif id == 'manual' then
        require('codeit.ui.input').show({ prompt = title .. ' model ID (blank = inherit): ', default = feature.model or '' }, function(value)
          if not valid() then return end
          if value ~= nil then store(); feature.model = vim.trim(value) end
          back()
        end)
      elseif id == 'model_clear' then
        store(); feature.model = nil; back()
      elseif id == 'reset' then
        entries[name] = nil; back()
      elseif id == 'options_clear' then
        store(); feature.options = nil; back()
      elseif id == 'preferred_provider' then
        choose_upstream(store(), selected.model, back, true)
      else
        local values = id == 'api_host' and settings.copilot_hosts
          or (id == 'routing_mode' and settings.routing_modes)
          or (id == 'allow_fallbacks' and settings.fallback_values)
          or (id == 'service_tier' and settings.tiers or settings.efforts)
        local choices = { { value = nil, label = '(inherit)' } }
        for _, value in ipairs(values) do
          choices[#choices + 1] = { value = value, label = id == 'routing_mode' and routing_label(value)
            or (id == 'allow_fallbacks' and fallback_label(value))
            or (value == '' and '(provider default)' or value) }
        end
        select(choices, { prompt = id, format_item = function(choice) return choice.label end }, function(choice)
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
    local items = {
      { id = 'provider', label = 'Backend: ' .. draft.provider },
      { id = 'model', label = 'Browse models: ' .. draft.models[draft.provider] },
      { id = 'manual', label = 'Enter model ID manually' },
    }
    if draft.provider == 'openrouter' then
      vim.list_extend(items, {
        { id = 'routing_mode', label = 'Routing mode: ' .. routing_label(options.routing_mode) },
        { id = 'preferred_provider', label = 'Preferred upstream provider: ' .. (options.preferred_provider or '') },
        { id = 'allow_fallbacks', label = 'Provider fallback: ' .. fallback_label(options.allow_fallbacks) },
        { id = 'service_tier', label = 'Service tier: ' .. (options.service_tier or '') },
        { id = 'effort', label = 'Reasoning effort: ' .. (options.effort or '') },
      })
    elseif draft.provider == 'codex' then
      items[#items + 1] = { id = 'effort', label = 'Reasoning effort: ' .. (options.effort or '') }
    elseif draft.provider == 'copilot' then
      items[#items + 1] = { id = 'effort', label = 'Reasoning effort: ' .. (options.effort or '') }
      items[#items + 1] = { id = 'api_host', label = 'Copilot API host: '
        .. (options.api_host and options.api_host ~= '' and options.api_host or 'api.githubcopilot.com (default)') }
    end
    for _, item in ipairs(items) do
      item.section = (item.id == 'provider' or item.id == 'model' or item.id == 'manual')
        and 'Main chat' or 'Main chat request options'
      if item.label:sub(-2) == ': ' then item.label = item.label .. '(provider default)' end
    end
    for _, name in ipairs(settings.presets) do
      local selected = settings.preset_config(draft, name)
      items[#items + 1] = { id = 'preset_' .. name, section = 'Shared model presets',
        label = 'Preset ' .. settings.preset_labels[name] .. ': ' .. selected.provider .. ' / ' .. selected.model }
    end
    for _, name in ipairs({ 'tool_assessment', 'tool_review', 'context_review', 'compaction', 'history_summary', 'cost_review', 'subagent' }) do
      local selected = settings.feature_config(draft, name)
      local assigned = settings.feature_preset(draft, name)
      items[#items + 1] = { id = name, section = 'Feature overrides', label = settings.feature_labels[name] .. ' ['
        .. (settings.preset_labels[assigned] or 'main') .. ']: ' .. selected.provider .. ' / ' .. selected.model }
    end
    vim.list_extend(items, {
      { id = 'session', label = 'Apply for this session' },
      { id = 'global', label = 'Apply and save globally' },
      { id = 'workspace', label = 'Apply and save for this workspace' },
    })
    for index = #items - 2, #items do items[index].section = 'Apply changes' end
    select(items, { prompt = 'Codeit settings (q/Esc to discard)',
      format_item = function(item) return item.label end }, function(item)
      if not item or not valid() then return end
      local id = item.id
      if id == 'provider' then
        select({ 'openrouter', 'copilot', 'codex' }, { prompt = 'Backend' }, function(provider)
          if not valid() then return end
          if provider then draft.provider = provider end
          menu()
        end)
      elseif id == 'model' then
        choose_model()
      elseif vim.tbl_contains(settings.features, id) then
        override_menu(id)
      elseif id:sub(1, 7) == 'preset_' and vim.tbl_contains(settings.presets, id:sub(8)) then
        override_menu(id:sub(8), true)
      elseif id == 'preferred_provider' then
        draft.request_options.openrouter = options
        choose_upstream(options)
      elseif id == 'manual' then
        require('codeit.ui.input').show({ prompt = 'Model ID: ', default = draft.models[draft.provider] }, function(value)
          if not valid() then return end
          if value ~= nil and vim.trim(value) ~= '' then
            draft.models[draft.provider] = vim.trim(value)
          end
          menu()
        end)
      elseif id == 'api_host' then
        select(settings.copilot_hosts, {
          prompt = 'Copilot API host',
          format_item = function(value) return value == '' and 'api.githubcopilot.com (default)' or value end,
        }, function(value)
          if not valid() then return end
          if value ~= nil then options.api_host = value; draft.request_options.copilot = options end
          menu()
        end)
      elseif id == 'routing_mode' or id == 'allow_fallbacks' or id == 'service_tier' or id == 'effort' then
        select(id == 'routing_mode' and settings.routing_modes or (id == 'allow_fallbacks' and settings.fallback_values)
          or (id == 'service_tier' and settings.tiers or settings.efforts), {
          prompt = id == 'routing_mode' and 'Routing mode (overrides preferred provider)'
            or (id == 'allow_fallbacks' and 'Provider fallback')
            or (id == 'service_tier' and 'Service tier (model/provider dependent)' or 'Reasoning effort (model dependent)'),
          format_item = function(value)
            return id == 'routing_mode' and routing_label(value) or (id == 'allow_fallbacks' and fallback_label(value))
              or (value == '' and '(provider default)' or value)
          end,
        }, function(value)
          if not valid() then return end
          if value ~= nil then options[id] = value; draft.request_options[draft.provider] = options end
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
