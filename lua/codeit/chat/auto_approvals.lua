local M = {}

function M.restore(value)
  local records = {}
  if type(value) ~= 'table' or not vim.islist(value) then return records end
  for _, record in ipairs(value) do
    if type(record) == 'table' and type(record.name) == 'string' and record.name ~= ''
      and type(record.args) == 'table' and record.args ~= vim.NIL
      and type(record.reason) == 'string' and type(record.timestamp) == 'number'
      and record.timestamp >= 0 and record.timestamp < math.huge then
      records[#records + 1] = vim.deepcopy(record)
    end
  end
  return records
end

-- Background subagents may outlive the active chat; keep their audit in the origin.
function M.recorder(session, helpers, workspace, id)
  return function(name, args, reason, details)
    local record = { name = name, args = vim.deepcopy(args), reason = reason, timestamp = os.time() }
    for key, value in pairs(details or {}) do record[key] = value end
    if session.workspace == workspace and session.chat_id == id then
      session.auto_approvals = session.auto_approvals or {}
      session.auto_approvals[#session.auto_approvals + 1] = record
      helpers.save()
      return
    end
    local history = require('codeit.chat.storage')
    local chat = history.load(workspace, id)
    if not chat then return end -- Never recreate a chat the user deleted.
    chat.auto_approvals = M.restore(chat.auto_approvals)
    chat.auto_approvals[#chat.auto_approvals + 1] = record
    local ok, err = history.save(workspace, id, chat)
    if not ok then vim.notify('codeit: could not save auto-approval: ' .. tostring(err), vim.log.levels.ERROR) end
  end
end

return M
