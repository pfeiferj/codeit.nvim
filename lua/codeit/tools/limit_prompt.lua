local M = {}
local prompt = require('codeit.tools.approval.prompt')
local approval_queue = require('codeit.ui.approval_queue')

-- This grants more rounds, not approval for the individual tools in those rounds.
function M.show(default_rounds, active, callback)
  local finished = false
  local function live() return not finished and active() end
  local function finish(rounds)
    if not live() then return end
    finished = true
    callback(rounds)
  end
  local function custom()
    if not live() then return end
    require('codeit.ui.input').show({ title = ' Additional tool rounds ', approval = true,
      prompt = 'Additional tool rounds: ',
      body = '# Extend tool limit\n\nEnter a **positive whole number** of additional tool-call rounds.\n\n'
        .. 'Each round may contain multiple calls. **Individual tool approvals still apply.**',
      default = tostring(math.max(1, default_rounds)) }, function(value)
      if not live() then return end
      if value == nil then return finish(nil) end
      local rounds = tonumber(vim.trim(value))
      if not rounds or rounds <= 0 or rounds >= math.huge or rounds ~= math.floor(rounds) then
        vim.notify('codeit: enter a positive whole number of additional tool rounds', vim.log.levels.WARN)
        return custom()
      end
      finish(rounds)
    end)
  end
  local options = {}
  if default_rounds > 0 then
    options[#options + 1] = { key = '1', id = 'continue', label = 'Continue with ' .. default_rounds .. ' additional tool rounds' }
  end
  options[#options + 1] = { key = '2', id = 'custom', label = 'Choose a custom number of additional tool rounds' }
  options[#options + 1] = { key = '3', id = 'stop', label = 'Decline additional tools' }
  approval_queue.enqueue(function()
    prompt.show('# Tool limit reached\n\nAllow the assistant to continue? Each round is one assistant tool-call batch, '
      .. 'which may contain multiple calls. Individual tool approvals still apply.\n\n'
      .. 'Declining sends limit errors for the pending calls and requests a final response without tools.', options, function(choice)
      if not live() then return end
      if choice == 'continue' and default_rounds > 0 then return finish(default_rounds) end
      if choice == 'custom' then return custom() end
      finish(nil)
    end, { title = ' Tool limit reached ', dismiss = 'Decline additional tools' })
  end, live, function(err)
    vim.notify('codeit: could not show tool limit prompt: ' .. tostring(err), vim.log.levels.ERROR)
    finish(nil)
  end)
end

return M
