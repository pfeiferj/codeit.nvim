local M = {}

-- Keep slash names in one place for completion and dispatch. Ex commands remain
-- the source of truth for behavior, including commands that take arguments.
local commands = {
  { name = 'toggle', command = 'Codeit' },
  { name = 'send', command = 'CodeitSend', args = true },
  { name = 'stop', command = 'CodeitStop' },
  { name = 'new', command = 'CodeitNew' },
  { name = 'compact', command = 'CodeitCompact' },
  { name = 'context', command = 'CodeitContext' },
  { name = 'contextFull', command = 'CodeitContextFull' },
  { name = 'contextFiles', command = 'CodeitContextFiles' },
  { name = 'systemPrompt', command = 'CodeitSystemPrompt' },
  { name = 'history', command = 'CodeitHistory' },
  { name = 'costs', command = 'CodeitCosts' },
  { name = 'tasks', command = 'CodeitTasks' },
  { name = 'trust', command = 'CodeitTrust', args = true },
  { name = 'untrust', command = 'CodeitUntrust' },
  { name = 'trustStatus', command = 'CodeitTrustStatus' },
  { name = 'provider', command = 'CodeitProvider', args = true },
  { name = 'settings', command = 'CodeitSettings' },
}

function M.complete_items()
  local items = {}
  for _, command in ipairs(commands) do
    items[#items + 1] = { word = '/' .. command.name, menu = ':' .. command.command }
  end
  return items
end

function M.parse(text)
  if text:find('\n', 1, true) or text:sub(1, 1) ~= '/' then return nil end
  local name, rest = text:match('^/([%w]+)(.*)$')
  if not name then return false, 'unknown slash command' end
  for _, command in ipairs(commands) do
    if name == command.name then
      if rest ~= '' and not rest:match('^%s') then break end
      local args = vim.trim(rest)
      if args ~= '' and not command.args then return false, '/' .. name .. ' does not take arguments' end
      return command, args
    end
  end
  return false, 'unknown slash command: /' .. name
end

return M
