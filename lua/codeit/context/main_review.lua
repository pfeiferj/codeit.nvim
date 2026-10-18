local M = {}
local review = require('codeit.context.review')

function M.specs(specs)
  local result = vim.deepcopy(specs)
  for _, definition in ipairs(result) do
    local fn = definition['function']
    if fn.name ~= 'ask_user' and fn.name ~= 'load_skill' then
      local parameters = fn.parameters
      parameters.properties.keep_in_context = { type = 'boolean',
        description = 'Whether to keep this call and its result in future context after the current user turn finishes. False removes both without a summary, but keeps them available throughout this turn. Keep unique implementation details, unresolved errors, and useful verification evidence; remove ephemeral or redundant data only when future work will not need it. When uncertain, use true.' }
      parameters.required = parameters.required or {}
      parameters.required[#parameters.required + 1] = 'keep_in_context'
    end
  end
  return result
end

function M.replacements(turn)
  local removed = {}
  for _, message in ipairs(turn) do
    for _, call in ipairs(message.tool_calls or {}) do
      local ok, args = pcall(vim.json.decode, call['function'].arguments or '')
      if ok and type(args) == 'table' and args.keep_in_context == false then removed[call.id] = true end
    end
  end
  local replacements = {}
  -- Candidates exclude protected exchanges and calls without a matching result.
  for _, candidate in ipairs(review.candidates(turn)) do
    if removed[candidate.tool_call_id] then
      replacements[#replacements + 1] = { tool_call_id = candidate.tool_call_id, remove = true }
    end
  end
  return review.validate(turn, replacements)
end

return M
