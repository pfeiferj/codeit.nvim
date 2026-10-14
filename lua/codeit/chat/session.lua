local M = {}
local ui = require('codeit.ui')
local history = require('codeit.chat.storage')
local context_files = require('codeit.context.files')
local settings = require('codeit.settings')
local defaults = require('codeit.settings.defaults')

function M.attach(api, session, helpers)
  local M = api
  function helpers.model()
    return session.chat_model or session.config.models[session.config.provider] or 'unknown'
  end

  function helpers.request_config(feature)
    if feature then return settings.feature_config(session.config, feature, helpers.model()) end
    return { provider = session.config.provider, model = helpers.model(),
      options = vim.deepcopy(session.config.request_options[session.config.provider] or {}) }
  end

  function helpers.apply_settings(values)
    session.config.provider = values.provider
    session.config.models = vim.tbl_extend('force', {}, defaults.models, values.models)
    session.config.model_presets = vim.deepcopy(values.model_presets or session.config.model_presets or {})
    session.config.feature_settings = vim.deepcopy(values.feature_settings or session.config.feature_settings or {})
    session.config.request_options = vim.deepcopy(values.request_options)
  end

  function helpers.save(clear_summary)
    if not session.chat_id or not session.workspace then return end
    local seconds, microseconds = vim.uv.gettimeofday()
    local ok, err = history.save(session.workspace, session.chat_id, {
      provider = session.config.provider, model = helpers.model(), messages = session.messages,
      command_results = session.command_results, auto_approvals = session.auto_approvals,
      request_options = session.config.request_options,
      model_presets = session.config.model_presets,
      feature_settings = session.config.feature_settings,
      updated_at = seconds + microseconds / 1000000, cost = session.cost, missing_cost = session.missing_cost,
      turn_costs = session.turn_costs, cost_by_function = session.cost_by_function,
      tokens_in = session.tokens_in, tokens_out = session.tokens_out, missing_in = session.missing_in,
      missing_out = session.missing_out, context_tokens = session.context_tokens, context_estimated = session.context_estimated,
      context_summary = session.context_summary, compacted_until = session.compacted_until,
      context_summary_skills = session.context_summary_skills,
      context_stats = session.context_stats,
      context_reviews = session.context_reviews,
      context_paths = session.context_paths, selected_skills = session.selected_skills,
      disabled_context_files = session.disabled_context_files,
    }, { clear_summary = clear_summary })
    if not ok then vim.notify('codeit: could not save chat: ' .. tostring(err), vim.log.levels.ERROR) end
  end

  function helpers.sync_workspace()
    local current = history.workspace()
    if session.workspace == current then return end
    local ok, err = require('codeit.workspaces').record(current)
    if not ok then
      vim.notify('codeit: could not remember workspace: ' .. tostring(err), vim.log.levels.ERROR)
    end
    session.generation = session.generation + 1
    session.stream_preview = nil
    session.busy = false
    session.workspace, session.chat_id, session.chat_model = current, nil, nil
    helpers.apply_settings(settings.resolve(session.base_settings, session.workspace))
    session.disabled_context_files = {}
    context_files.set_disabled(session.workspace, session.disabled_context_files)
    session.messages = {}
    session.session_prompt = nil
    session.context_summary, session.compacted_until, session.context_summary_skills = nil, nil, nil
    session.context_reviews = {}
    session.context_paths, session.selected_skills = {}, {}
    session.read_versions = {}
    session.auto_approvals = {}
    session.cost, session.missing_cost = 0, 0
    session.turn_costs, session.current_turn = {}, nil
    session.cost_by_function = {}
    session.tokens_in, session.tokens_out, session.missing_in, session.missing_out = 0, 0, false, false
    session.context_tokens, session.context_estimated = nil, nil
    session.context_stats = { cached_tokens = 0, cache_observed_tokens = 0, main_requests = 0, compactions = {} }
    session.turn_reviews = nil
    session.source = nil
    session.command_results = {}
    session.status = 'Ready (new workspace)'
  end

  function M.workspaces()
    helpers.sync_workspace()
    return require('codeit.workspace_review').show()
  end

  function M.open()
    helpers.sync_workspace()
    if not ui.is_open() then
      local current = vim.api.nvim_get_current_buf()
      if vim.bo[current].buftype == '' then session.source = current end
    end
    ui.open(M.send, M.close)
    helpers.render()
  end

  function M.stop()
    helpers.sync_workspace()
    if not session.busy then return false end
    session.generation = session.generation + 1
    session.busy = false
    -- Balance unfinished tool batches without discarding results or completed edits.
    local answered, calls = {}
    for i = #session.messages, 1, -1 do
      local message = session.messages[i]
      if message.role == 'assistant' then calls = message.tool_calls; break end
      if message.role ~= 'tool' then break end
      answered[message.tool_call_id] = true
    end
    for _, call in ipairs(type(calls) == 'table' and calls or {}) do
      if not answered[call.id] then
        session.messages[#session.messages + 1] = { role = 'tool', tool_call_id = call.id,
          content = 'Interrupted by user. This call did not complete; any side effects already performed are not undone.' }
      end
    end
    if type(session.stream_preview) == 'string' and session.stream_preview ~= '' then
      session.messages[#session.messages + 1] = { role = 'assistant', content = session.stream_preview }
    end
    session.stream_preview = nil
    session.turn_reviews, session.current_turn = nil, nil
    helpers.save()
    helpers.set_status('Turn interrupted')
    return true
  end

  function M.close()
    ui.close()
  end

  function M.toggle()
    if ui.is_open() and vim.api.nvim_get_current_tabpage() == require('codeit.ui.managed_tab').tab() then
      M.close()
    else
      M.open()
    end
  end

  function M.new()
    helpers.sync_workspace()
    session.generation = session.generation + 1
    session.stream_preview = nil
    session.busy = false
    session.chat_id, session.chat_model = nil, nil
    session.messages = {}
    session.session_prompt = nil
    session.context_summary, session.compacted_until, session.context_summary_skills = nil, nil, nil
    session.context_reviews = {}
    session.context_paths, session.selected_skills, session.disabled_context_files = {}, {}, {}
    session.read_versions = {}
    session.auto_approvals = {}
    context_files.set_disabled(session.workspace, session.disabled_context_files)
    session.cost, session.missing_cost = 0, 0
    session.turn_costs, session.current_turn = {}, nil
    session.cost_by_function = {}
    session.tokens_in, session.tokens_out, session.missing_in, session.missing_out = 0, 0, false, false
    session.context_tokens, session.context_estimated = nil, nil
    session.context_stats = { cached_tokens = 0, cache_observed_tokens = 0, main_requests = 0, compactions = {} }
    session.turn_reviews = nil
    session.status = 'New conversation'
    session.command_results = {}
    helpers.render()
  end

  function M.set_provider(name)
    if name ~= 'openrouter' and name ~= 'copilot' and name ~= 'codex' then
      vim.notify('codeit: provider must be openrouter, copilot, or codex', vim.log.levels.ERROR)
      return
    end
    M.new()
    session.config.provider = name
    helpers.render()
  end

  function helpers.set_status(text)
    session.status = text
    helpers.render()
  end

  function helpers.fail(err)
    session.turn_reviews, session.current_turn = nil, nil
    session.busy = false
    helpers.set_status('Error: ' .. tostring(err))
    vim.notify('codeit: ' .. tostring(err), vim.log.levels.ERROR)
  end

  function helpers.complete()
    session.turn_reviews, session.current_turn = nil, nil
    session.busy = false
    helpers.set_status('Ready')
  end
end

return M
