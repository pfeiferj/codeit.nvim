local M = {}
local initial_ms, extension_ms, warning_ms = 240000, 120000, 30000

-- This deadline belongs to the live connection, not a retry of the request.
function M.start(stop, active, model)
  local started = vim.uv.now()
  local deadline, last_activity = started + initial_ms, nil
  local finished, asked = false, false
  local timer, cancel_queued, close_prompt, update_prompt
  local last_render
  local function cleanup()
    if finished then return end
    finished = true
    if timer then timer:stop(); timer:close(); timer = nil end
    if cancel_queued then cancel_queued(); cancel_queued = nil end
    if close_prompt then close_prompt(); close_prompt = nil end
    update_prompt = nil
  end
  local function finish(err)
    if finished then return end
    cleanup()
    stop(err)
  end
  local function live()
    return not finished and (not active or active()) and vim.uv.now() < deadline
  end
  local function text()
    local now = vim.uv.now()
    local activity = last_activity and string.format('Last response activity: %d seconds ago.',
      math.floor((now - last_activity) / 1000))
      or 'No response data received yet. Non-streaming requests may not report progress.'
    local label = tostring(model or 'unknown'):gsub('[%c`]', ' ')
    return table.concat({ '# Extend provider request?', '', 'Model: `' .. label .. '`', '',
      string.format('Elapsed: %d seconds. Deadline in: %d seconds.', math.floor((now - started) / 1000),
        math.max(0, math.ceil((deadline - now) / 1000))), activity, '',
      'Approve **2 more minutes** on the existing connection. This does not resend the request.',
      'Without approval, the request stops at its current deadline. Stopping may still incur provider charges.',
    }, '\n')
  end
  local function ask()
    asked = true
    cancel_queued = require('codeit.ui.approval_queue').enqueue(function()
      if not live() then return end
      update_prompt, close_prompt = require('codeit.tools.approval.prompt').show(text(), {
        { key = 's', id = 'stop', label = 'Stop request' },
        { key = 'e', id = 'extend', label = 'Extend by 2 minutes' },
      }, function(choice)
        close_prompt, update_prompt = nil, nil
        if finished then return end
        if active and not active() then return finish() end
        -- A delayed keypress must not authorize an already expired request.
        if vim.uv.now() >= deadline then return finish('Provider request timed out: extension not approved') end
        if choice == 'extend' then
          deadline, asked = deadline + extension_ms, false
        else
          finish('Provider request stopped: timeout extension declined')
        end
      end, { title = ' Extend provider request? ', dismiss = 'Stop request' })
      last_render = vim.uv.now()
    end, live, function(err)
      finish('Could not show provider timeout approval: ' .. tostring(err))
    end)
  end
  timer = vim.uv.new_timer()
  timer:start(50, 50, vim.schedule_wrap(function()
    if finished then return end
    if active and not active() then return finish() end
    local now = vim.uv.now()
    if now >= deadline then return finish('Provider request timed out: extension not approved') end
    if not asked and now >= deadline - warning_ms then ask() end
    if update_prompt and now - last_render >= 1000 then
      update_prompt(text())
      last_render = now
    end
  end))
  return cleanup, function()
    if not finished then last_activity = vim.uv.now() end
  end
end

return M
