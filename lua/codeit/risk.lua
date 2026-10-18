local M = {}

local function renamed(value, old_key, new_key)
  -- Tool validation normalizes optional fields in place; only copy legacy inputs.
  if type(value) ~= 'table' or value == vim.NIL or value[old_key] == nil then return value end
  local result = vim.tbl_extend('force', {}, value)
  if result[new_key] == nil then result[new_key] = result[old_key] end
  result[old_key] = nil
  return result
end

function M.approval(value)
  return renamed(value, 'tool_call_safety', 'tool_call_risk')
end

function M.settings(value)
  if type(value) ~= 'table' or value == vim.NIL then return value end
  local result = vim.deepcopy(value)
  result.approval = M.approval(result.approval)
  return result
end

function M.assessment(value)
  return renamed(value, 'safety_score', 'risk_score')
end

return M
