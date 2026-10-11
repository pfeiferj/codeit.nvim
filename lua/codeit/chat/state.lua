local M = {}

function M.new(defaults)
  local session = {}
  session.config = vim.deepcopy(defaults)
  session.base_settings = { provider = session.config.provider, models = vim.deepcopy(session.config.models),
    model_presets = vim.deepcopy(session.config.model_presets),
    feature_settings = vim.deepcopy(session.config.feature_settings), request_options = {} }
  session.messages, session.command_results = {}, {}

  session.context_reviews, session.review_revision = {}, 0
  session.context_paths, session.selected_skills, session.disabled_context_files = {}, {}, {}
  session.read_versions = {}
  session.cost, session.missing_cost = 0, 0
  -- Keep billing outside messages so late charges do not invalidate context-review snapshots.
  session.turn_costs, session.current_turn = {}, nil
  session.cost_by_function = {}
  session.tokens_in, session.tokens_out, session.missing_in, session.missing_out = 0, 0, false, false

  session.context_stats = { cached_tokens = 0, cache_observed_tokens = 0, main_requests = 0, compactions = {} }

  session.busy = false
  session.generation = 0

  session.pending_summaries = {}
  session.history_view = 0
  session.status = 'Ready. Type below; press Enter in normal mode or Ctrl-S in insert mode to send.'

  return session
end

return M
