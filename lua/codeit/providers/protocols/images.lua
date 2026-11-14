local M = {}

function M.present(messages)
  for _, message in ipairs(messages) do
    if type(message.content) == 'table' then
      for _, part in ipairs(message.content) do
        if part.type == 'image_url' then return true end
      end
    end
  end
  return false
end

-- Image-bearing tool outputs are not portable across APIs. Keep the call's text
-- result, then supply native user image parts after the entire tool-result batch.
function M.messages(messages)
  local result, images = {}, {}
  local function flush()
    if #images == 0 then return end
    result[#result + 1] = { role = 'user', content = images }
    images = {}
  end
  for _, message in ipairs(messages) do
    if message.role ~= 'tool' then flush() end
    local content = message.content
    local has_image = false
    if message.role == 'tool' and type(content) == 'table' then
      for _, part in ipairs(content) do
        if part.type == 'image_url' then has_image = true; break end
      end
    end
    if has_image then
      local text = {}
      for _, part in ipairs(content) do
        if part.type == 'text' then text[#text + 1] = part.text end
      end
      local label = 'Image from tool call ' .. message.tool_call_id .. ': ' .. table.concat(text, '\n')
      images[#images + 1] = { type = 'text', text = label }
      for _, part in ipairs(content) do
        if part.type == 'image_url' then images[#images + 1] = part end
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
