local M = {}

function M.body(model, messages, tools, on_text, tool_choice)
  local body = { model = model, messages = {} }
  for _, message in ipairs(messages) do
    local copy = vim.tbl_extend('force', {}, message)
    -- Responses replay metadata is private, not a chat-completions message field.
    copy._copilot_reasoning = nil
    copy._codex_reasoning = nil
    body.messages[#body.messages + 1] = copy
  end
  if tools and #tools > 0 then
    body.tools = tools
    body.tool_choice = tool_choice or 'auto'
  end
  if on_text then
    body.stream = true
    body.stream_options = { include_usage = true }
  end
  return body
end

function M.message(response, capped)
  local choice = type(response) == 'table' and type(response.choices) == 'table' and response.choices[1]
  if type(choice) ~= 'table' or type(choice.message) ~= 'table' then
    return nil, 'Response has no assistant message', vim.json.encode(response)
  end
  if capped and choice.finish_reason == 'length' then
    return nil, 'Summary output reached its token cap', vim.json.encode(response), true
  end
  local message = choice.message
  if type(message.refusal) == 'string'
    and (message.content == nil or message.content == vim.NIL or message.content == ''
      or (type(message.content) == 'table' and vim.islist(message.content) and #message.content == 0)) then
    message.content = message.refusal
  end
  return message
end

return M
