local M = {}
local ui = require('codeit.ui')
local cost_breakdown = require('codeit.cost_breakdown')

function M.attach(api, session, helpers)
  local M = api
  local usage_format = require('codeit.usage_format')
  local format_tokens = usage_format.tokens

  function helpers.render()
    local billing, compact
    if session.config.provider == 'openrouter' or session.config.provider == 'copilot' or session.config.provider == 'codex'
      or session.config.provider == 'openai'
      or session.cost > 0 or session.missing_cost > 0 then
      local subscription_count, dollars = cost_breakdown.subscription_requests(session.cost_by_function)
      local cost = 'Cost: ' .. usage_format.cost(session.cost, session.missing_cost > 0)
      compact = session.config.provider == 'codex' or subscription_count > 0
      if compact then
        cost = usage_format.with_subscription(usage_format.subscription(session.codex_subscription, true),
          session.cost, session.missing_cost > 0, dollars)
      end
      billing = string.format(compact and '%s | In:%s%s | Out:%s%s | Ctx:%s' or '%s | In: %s%s | Out: %s%s | Context: %s',
        cost, format_tokens(session.tokens_in, 1000000, 'm'), session.missing_in and '+' or '',
        format_tokens(session.tokens_out, 1000000, 'm'), session.missing_out and '+' or '',
        session.context_tokens and (session.context_estimated and '~' or '') .. format_tokens(session.context_tokens, 1000, 'k') or '—')
    end
    if billing and session.context_stats.cache_observed_tokens > 0 then
      billing = billing .. string.format(compact and ' | Cache:%.0f%%' or ' | Cache: %.0f%%',
        session.context_stats.cached_tokens / session.context_stats.cache_observed_tokens * 100)
    end
    local displayed = session.messages
    if session.stream_preview then
      displayed = vim.list_extend({}, session.messages)
      displayed[#displayed + 1] = { role = 'assistant', content = session.stream_preview }
    end
    ui.render(displayed, session.status, session.config.provider, helpers.model(), billing, session.command_results,
      not session.busy, session.turn_costs, session.last_agent_activity)
  end

  function helpers.usage_number(value)
    local number = (type(value) == 'number' or type(value) == 'string') and tonumber(value) or nil
    if number and number >= 0 and number < math.huge then return number end
  end

  function helpers.record_subscription(usage, provider)
    if provider == 'codex' and usage and usage.codex_subscription then
      session.codex_subscription = vim.tbl_extend('force', session.codex_subscription or {}, usage.codex_subscription)
    end
  end

  function helpers.record_usage(usage, feature, provider, turn)
    provider = provider or session.config.provider
    if provider ~= 'openrouter' and provider ~= 'copilot' and provider ~= 'codex' and provider ~= 'openai'
      and not (feature == 'context_review' and (provider == 'typesafe' or provider == 'decisions')) then return end
    helpers.record_subscription(usage, provider)
    -- Subscription requests are accounted for in quota, not in per-request USD charges.
    local subscription = provider == 'codex'
    local amount = subscription and 0 or helpers.usage_number(usage and usage.cost)
    if amount then session.cost = session.cost + amount else session.missing_cost = session.missing_cost + 1 end
    local input_count = helpers.usage_number(usage and usage.prompt_tokens)
    local output_count = helpers.usage_number(usage and usage.completion_tokens)
    cost_breakdown.add(session.cost_by_function, feature, amount, input_count, output_count, subscription)
    if turn then
      if amount then turn.cost = turn.cost + amount else turn.missing_cost = turn.missing_cost + 1 end
      turn.cost_by_function = turn.cost_by_function or {}
      cost_breakdown.add(turn.cost_by_function, feature, amount, input_count, output_count, subscription)
    end
    if input_count then session.tokens_in = session.tokens_in + input_count else session.missing_in = true end
    if output_count then session.tokens_out = session.tokens_out + output_count else session.missing_out = true end
    if feature == 'main_chat' then
      session.context_stats.main_requests = session.context_stats.main_requests + 1
      local cached = helpers.usage_number(usage and usage.cached_tokens)
      if cached and input_count then
        session.context_stats.cached_tokens = session.context_stats.cached_tokens + math.min(cached, input_count)
        session.context_stats.cache_observed_tokens = session.context_stats.cache_observed_tokens + input_count
      end
      session.context_estimated = false
      -- Review requests contribute to totals but do not describe the main chat's context.
      session.context_tokens = helpers.usage_number(usage and usage.total_tokens)
        or (input_count and output_count and input_count + output_count)
    end
    helpers.render()
    helpers.save()
  end

  function M.context_stats()
    helpers.sync_workspace()
    return vim.deepcopy(session.context_stats)
  end

  function M.auto_approvals()
    helpers.sync_workspace()
    helpers.save()
    return require('codeit.auto_approval_review').show(helpers.request_config('tool_review'), session.workspace)
  end

  function M.costs()
    helpers.sync_workspace()
    return require('codeit.cost_review').show(helpers.request_config('cost_review'), session.workspace)
  end
end

return M
