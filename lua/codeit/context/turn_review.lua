local M = {}
local context_review = require('codeit.context.review')
local providers = require('codeit.providers')
local history = require('codeit.chat.storage')

function M.attach(api, session, helpers)
  local M = api
  -- Each review owns a completed immutable turn, not the entire conversation.
  -- New turns can proceed and reviews can finish out of order without overwriting
  -- newer context. Manual context changes invalidate outstanding review snapshots.
  function helpers.review_turn()
    if not session.config.context_review then return end
    local last, first = #session.messages
    for i = last, 2, -1 do
      if session.messages[i].role == 'user' then first = i; break end
    end
    if not first then return end
    local billed_turn
    for _, turn_cost in ipairs(session.turn_costs) do
      if turn_cost.first == first then billed_turn = turn_cost; break end
    end
    local id, revision, selected_workspace, selected_chat = session.generation, session.review_revision, session.workspace, session.chat_id
    local original = vim.deepcopy(vim.list_slice(session.messages, first, last))
    local turn = vim.deepcopy(helpers.redact_disabled_skill_results(original))
    -- Encrypted provider reasoning is not useful to the reviewer.
    for _, message in ipairs(turn) do
      message._copilot_reasoning, message._codex_reasoning = nil, nil
    end
    local replaceable = context_review.replaceable_tokens(turn)
    if replaceable == 0 or replaceable < session.config.context_review_min_tokens then return end
    local selected_config = helpers.request_config('context_review')
    local function active()
      return id == session.generation and revision == session.review_revision and session.workspace == selected_workspace
        and history.workspace() == selected_workspace and session.chat_id == selected_chat
        and first > (session.compacted_until or 1)
        and vim.deep_equal(original, vim.list_slice(session.messages, first, last))
    end
    vim.schedule(function()
      if not active() then return end
      providers.chat(selected_config, {
        { role = 'system', content = context_review.prompt },
        { role = 'user', content = vim.json.encode(turn) },
      }, {}, function(message, err, usage)
        if id ~= session.generation or session.workspace ~= selected_workspace or history.workspace() ~= selected_workspace
          or session.chat_id ~= selected_chat then return end
        -- Background requests contribute to billing, never to main-chat context usage.
        if not err then helpers.record_usage(usage, 'context_review', selected_config.provider, billed_turn) end
        if not active() then return end
        local replacements
        if not err then replacements, err = context_review.parse(message, turn) end
        if err then
          vim.notify('codeit: could not review context: ' .. tostring(err), vim.log.levels.WARN)
          return
        end
        if #replacements == 0 then return end
        session.context_reviews[#session.context_reviews + 1] = { first = first, last = last, replacements = replacements }
        table.sort(session.context_reviews, function(a, b) return a.first < b.first end)
        helpers.estimate_context()
        helpers.save()
        helpers.render() -- Preserve the active turn's status and draft.
      end)
    end)
  end
end

return M
