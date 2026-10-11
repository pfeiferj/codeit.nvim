local M = {}

-- Shared metadata drives the palette, argument guidance, and dispatch.
local commands = {
  { name = 'toggle', command = 'Codeit', description = 'Toggle the chat' },
  { name = 'send', command = 'CodeitSend', description = 'Send a message', args = true,
    required = true, hint = 'Enter the message to send' },
  { name = 'skill', command = 'CodeitSkill', description = 'Invoke a skill with optional arguments', args = true,
    required = true, hint = 'Enter a skill name followed by optional literal arguments' },
  { name = 'stop', command = 'CodeitStop', description = 'Stop the current response' },
  { name = 'new', command = 'CodeitNew', description = 'Start a new conversation' },
  { name = 'compact', command = 'CodeitCompact', description = 'Summarize conversation to reduce context' },
  { name = 'context', command = 'CodeitContext', description = 'Review the current context' },
  { name = 'contextFull', command = 'CodeitContextFull', description = 'Edit the full context' },
  { name = 'contextFiles', command = 'CodeitContextFiles', description = 'Manage attached files' },
  { name = 'systemPrompt', command = 'CodeitSystemPrompt', description = 'Edit the system prompt' },
  { name = 'history', command = 'CodeitHistory', description = 'Browse saved conversations' },
  { name = 'costs', command = 'CodeitCosts', description = 'Review chat costs' },
  { name = 'tasks', command = 'CodeitTasks', description = 'Review background tasks' },
  { name = 'subagents', command = 'CodeitSubagents', description = 'Review subagent runs and chat logs' },
  { name = 'trust', command = 'CodeitTrust', description = 'Trust this workspace for reads', args = true,
    choices = { 'all', 'tracked' }, hint = 'Choose all or tracked; omit to open the trust picker' },
  { name = 'untrust', command = 'CodeitUntrust', description = 'Revoke workspace read trust' },
  { name = 'trustStatus', command = 'CodeitTrustStatus', description = 'Show workspace trust status' },
  { name = 'provider', command = 'CodeitProvider', description = 'Switch provider', args = true,
    required = true, choices = { 'openrouter', 'copilot', 'codex' }, hint = 'Choose a provider' },
  { name = 'settings', command = 'CodeitSettings', description = 'Configure Codeit' },
  { name = 'help', description = 'Open the searchable command palette' },
}

local function normalize(name)
  return name:lower():gsub('%-', '')
end

local function find(name)
  for _, command in ipairs(commands) do
    if normalize(name) == normalize(command.name) then return command end
  end
end

function M.complete_items(prefix)
  prefix = normalize(prefix or '/')
  local items = {}
  for _, command in ipairs(commands) do
    if normalize('/' .. command.name):sub(1, #prefix) == prefix then
      items[#items + 1] = { word = '/' .. command.name, menu = command.description,
        command = command }
    end
  end
  return items
end

function M.complete(text)
  if text:match('^/[%w%-]*$') then return M.complete_items(text), 0 end
  local name, args = text:match('^/([%w%-]+)%s+(.*)$')
  local command = name and find(name)
  if not command or not command.args then return {}, 0 end
  local items = {}
  if command.name == 'skill' and not args:find('%s') then
    local workspace = require('codeit.history').workspace()
    for _, entry in ipairs(require('codeit.context_files').entries(workspace, require('codeit.tools.approval').workspace_trust(workspace))) do
      if entry.kind == 'skill' and entry.available and entry.name:sub(1, #args) == args then
        items[#items + 1] = { word = entry.name, menu = entry.description }
      end
    end
    return items, #text - #args, command.hint
  end
  for _, choice in ipairs(command.choices or {}) do
    if choice:sub(1, #args) == args then
      items[#items + 1] = { word = choice, menu = command.hint }
    end
  end
  return items, #text - #args, command.hint
end

local function distance(a, b)
  local previous = {}
  for j = 0, #b do previous[j] = j end
  for i = 1, #a do
    local row = { [0] = i }
    for j = 1, #b do
      row[j] = math.min(row[j - 1] + 1, previous[j] + 1,
        previous[j - 1] + (a:sub(i, i) == b:sub(j, j) and 0 or 1))
    end
    previous = row
  end
  return previous[#b]
end

function M.parse(text)
  if text:find('\n', 1, true) or text:sub(1, 1) ~= '/' or text:sub(1, 2) == '//' then return nil end
  local name, rest = text:match('^/([%w%-]+)(.*)$')
  if not name then return false, 'Unknown slash command; use /help to browse commands' end
  local command = find(name)
  if command and (rest == '' or rest:match('^%s')) then
    local args = vim.trim(rest)
    if args ~= '' and not command.args then return false, '/' .. name .. ' does not take arguments' end
    return command, args
  end
  local nearest, best = nil, 3
  -- Bound typo matching for arbitrarily long drafts.
  if #name <= 40 then
    for _, candidate in ipairs(commands) do
      local score = distance(normalize(name), normalize(candidate.name))
      if score < best then nearest, best = candidate.name, score end
    end
  end
  return false, 'Unknown command /' .. name .. (nearest and (' — did you mean /' .. nearest .. '?')
    or '; use /help to browse commands')
end

function M.validate(command, args)
  if command.required and args == '' then return '/' .. command.name .. ': ' .. command.hint end
  if args ~= '' and command.choices and not vim.tbl_contains(command.choices, args) then
    return '/' .. command.name .. ': choose ' .. table.concat(command.choices, ' or ')
  end
end

function M.literal(text)
  if not text:find('\n', 1, true) and text:sub(1, 2) == '//' then return text:sub(2) end
  return text
end

return M
