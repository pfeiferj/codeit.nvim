local M = {}
M.tiers = { '', 'default', 'flex', 'priority', 'fast', 'ultrafast' }
M.routing_modes = { '', 'auto', 'price', 'latency', 'throughput' }
M.fallback_values = { '', true, false }
M.response_healing_values = { '', true, false }
M.efforts = { '', 'none', 'minimal', 'low', 'medium', 'high', 'xhigh' }
M.copilot_hosts = { '', 'api.githubcopilot.com', 'api.business.githubcopilot.com' }
M.features = { 'tool_assessment', 'tool_review', 'context_review', 'history_summary', 'compaction', 'cost_review', 'subagent' }
M.presets = { 'fast', 'long_context', 'reasoning' }
M.preset_labels = { fast = 'fast', long_context = 'long context', reasoning = 'reasoning' }
M.feature_presets = {
  tool_assessment = 'fast', tool_review = 'reasoning', context_review = 'long_context',
  history_summary = 'fast', compaction = 'long_context', cost_review = 'fast', subagent = 'fast',
}
M.feature_labels = {
  tool_assessment = 'Tool safety assessments', tool_review = 'Interactive tool reviews',
  context_review = 'Background context review', history_summary = 'History summaries', compaction = 'Compaction',
  cost_review = 'Cost review chat', subagent = 'Subagents',
}
M.option_providers = { preferred_provider = 'openrouter', service_tier = 'openrouter', routing_mode = 'openrouter',
  allow_fallbacks = 'openrouter', response_healing = 'openrouter', effort = 'openrouter',
  api_host = 'copilot', base_url = 'openai', api_key_env = 'openai' }

return M
