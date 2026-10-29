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
    local config = feature and settings.feature_config(session.config, feature, helpers.model())
      or { provider = session.config.provider, model = helpers.model(),
        options = vim.deepcopy(session.config.request_options[session.config.provider] or {}) }
    if session.chat_id then
      config.cache_key = vim.fn.sha256(vim.json.encode({ 'codeit', session.workspace or '', session.chat_id, feature or 'main' }))
    end
    return config
  end

  function helpers.apply_settings(values)
    values = require('codeit.risk').settings(values)
    session.config.provider = values.provider
    if values.context_review ~= nil then session.config.context_review = values.context_review end
    if values.personal_wiki ~= nil then
      if not vim.deep_equal(values.personal_wiki, session.config.personal_wiki) then
        session.wiki_revision = (session.wiki_revision or 0) + 1
      end
      session.config.personal_wiki = vim.deepcopy(values.personal_wiki)
    end
    session.config.models = vim.tbl_extend('force', {}, defaults.models, values.models)
    session.config.model_presets = vim.deepcopy(values.model_presets or session.config.model_presets or {})
    session.config.feature_settings = vim.deepcopy(values.feature_settings or session.config.feature_settings or {})
    session.config.request_options = vim.deepcopy(values.request_options)
    if values.approval and values.approval.tool_call_risk ~= nil
      and values.approval.tool_call_risk ~= session.config.approval.tool_call_risk then
      session.config.approval.tool_call_risk = values.approval.tool_call_risk
      require('codeit.tools').configure(session.config.approval)
    end
    if values.max_context_tokens ~= nil then
      if values.max_context_tokens == 'auto' then session.config.max_context_tokens = nil
      else session.config.max_context_tokens = values.max_context_tokens end
    end
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
    session.codex_subscription = nil
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

  function helpers.stop(reason)
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
          content = reason .. '. This call did not complete; any side effects already performed are not undone.' }
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

  function M.stop()
    return helpers.stop('Interrupted by user')
  end

  function M.close()
    ui.close()
  end

  function M.render_chat()
    return ui.render_chat()
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
    session.codex_subscription = nil
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

  function M.clear()
    helpers.sync_workspace()
    local prompt = helpers.current_prompt()
    session.generation = session.generation + 1
    session.busy, session.stream_preview = false, nil
    session.messages = { { role = 'system', content = prompt } }
    session.command_results = {}
    session.context_summary, session.compacted_until, session.context_summary_skills = nil, nil, nil
    session.context_reviews = {}
    session.review_revision = session.review_revision + 1
    session.context_paths, session.selected_skills = {}, {}
    session.read_versions = {}
    -- Per-turn costs reference message indices that no longer exist; totals remain intact.
    session.turn_costs, session.current_turn, session.turn_reviews = {}, nil, nil
    helpers.estimate_context()
    helpers.save(true)
    helpers.set_status('Context cleared')
  end

  function M.set_provider(name)
    if name ~= 'openrouter' and name ~= 'copilot' and name ~= 'codex' and name ~= 'openai' then
      vim.notify('codeit: provider must be openrouter, copilot, codex, or openai', vim.log.levels.ERROR)
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
