local M = {}

function M.present(messages, part_type)
  for _, message in ipairs(messages) do
    if type(message.content) == 'table' then
      for _, part in ipairs(message.content) do
        if part_type and part.type == part_type or not part_type and require('codeit.attachments').is_part(part) then return true end
      end
    end
  end
  return false
end

-- Native attachments are not portable in tool outputs. Keep the call's text
-- result, then supply user attachment parts after the entire tool-result batch.
function M.messages(messages)
  local result, attachments = {}, {}
  local function flush()
    if #attachments == 0 then return end
    result[#result + 1] = { role = 'user', content = attachments }
    attachments = {}
  end
  for _, message in ipairs(messages) do
    if message.role ~= 'tool' then flush() end
    local content = message.content
    local has_attachment = false
    if message.role == 'tool' and type(content) == 'table' then
      for _, part in ipairs(content) do
        if require('codeit.attachments').is_part(part) then has_attachment = true; break end
      end
    end
    if has_attachment then
      local text = {}
      for _, part in ipairs(content) do
        if part.type == 'text' then text[#text + 1] = part.text end
      end
      local label = 'Attachment from tool call ' .. message.tool_call_id .. ': ' .. table.concat(text, '\n')
      attachments[#attachments + 1] = { type = 'text', text = label }
      for _, part in ipairs(content) do
        if require('codeit.attachments').is_part(part) then attachments[#attachments + 1] = part end
      end
      result[#result + 1] = vim.tbl_extend('force', {}, message, { content = table.concat(text, '\n') })
    else
      result[#result + 1] = message
    end
  end
  flush()
  return result
end

return M
