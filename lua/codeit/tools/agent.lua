local M = { specs = {} }
local handlers = {}
local groups = {
  require('codeit.tools.workspace.search'),
  require('codeit.tools.workspace.files'),
  require('codeit.tools.execution.commands'),
  require('codeit.tools.workspace.diagnostics'),
  require('codeit.tools.workspace.git'),
  require('codeit.tools.execution.http'),
}
for _, group in ipairs(groups) do
  vim.list_extend(M.specs, group.specs)
  for _, definition in ipairs(group.specs) do
    handlers[definition['function'].name] = group
  end
end

function M.execute(name, args, done, ...)
  local handler = handlers[name]
  if not handler then return done('Error: unknown tool ' .. tostring(name)) end
  return handler.execute(name, args, done, ...)
end

return M
