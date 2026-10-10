local M = {}

local function content(value, role)
  if value == nil or value == vim.NIL then return nil end
  if type(value) == 'string' then return value end
  if type(value) ~= 'table' or not vim.islist(value) then return nil, 'Invalid message content' end
  local parts = {}
  for _, part in ipairs(value) do
    if part.type == 'text' then
      parts[#parts + 1] = { type = role == 'assistant' and 'output_text' or 'input_text', text = part.text }
      if role == 'assistant' then parts[#parts].annotations = {} end
    elseif part.type == 'image_url' and role == 'user' and type(part.image_url) == 'table' then
      parts[#parts + 1] = { type = 'input_image', image_url = part.image_url.url, detail = part.image_url.detail }
    else
      return nil, 'Unsupported Copilot Responses content part: ' .. tostring(part.type)
    end
  end
  return parts
end

--- Convert the shared chat-completions transcript to a stateless Responses request.
function M.body(model, messages, tools)
  local input = {}
  for _, message in ipairs(messages) do
    local value, err = content(message.content, message.role)
    if err then return nil, err end
    if message.role == 'assistant' then
      -- Reasoning models need their encrypted reasoning replayed across tool rounds.
      vim.list_extend(input, message._copilot_reasoning or {})
    end
    if message.role == 'tool' then
      input[#input + 1] = { type = 'function_call_output', call_id = message.tool_call_id, output = value or '' }
    else
      if value ~= nil and value ~= '' then
        input[#input + 1] = { role = message.role, content = value }
      end
      for _, call in ipairs(message.tool_calls or {}) do
        input[#input + 1] = {
          type = 'function_call', call_id = call.id,
          name = call['function'].name, arguments = call['function'].arguments,
        }
      end
    end
  end
  local body = {
    model = model, input = input, stream = false, store = false,
    include = { 'reasoning.encrypted_content' },
  }
  if tools and #tools > 0 then
    body.tools = {}
    for _, tool in ipairs(tools) do
      local fn = tool['function']
      body.tools[#body.tools + 1] = {
        type = 'function', name = fn.name, description = fn.description, parameters = fn.parameters,
        -- Existing tools use optional arguments, unlike Responses' default strict schemas.
        strict = false,
      }
    end
    body.tool_choice = 'auto'
  end
  return body
end

--- Normalize a Responses result for the existing chat/tool execution loop.
function M.message(response)
  if type(response) ~= 'table' then return nil, 'Invalid Copilot Responses result' end
  if response.status and response.status ~= 'completed' then
    local detail = type(response.error) == 'table' and response.error.message
      or type(response.incomplete_details) == 'table' and response.incomplete_details.reason
    return nil, 'Copilot response ' .. tostring(response.status) .. (detail and ': ' .. detail or '')
  end
  if type(response.output) ~= 'table' or not vim.islist(response.output) then
    return nil, 'Response has no assistant message'
  end
  local texts, calls, reasoning = {}, {}, {}
  for _, item in ipairs(response.output) do
    if type(item) ~= 'table' then return nil, 'Malformed output item from Copilot Responses' end
    if item.type == 'message' and item.role == 'assistant' then
      if type(item.content) ~= 'table' or not vim.islist(item.content) then
        return nil, 'Malformed message content from Copilot Responses'
      end
      local parts = {}
      for _, part in ipairs(item.content) do
        if type(part) ~= 'table' then return nil, 'Malformed content part from Copilot Responses' end
        if part.type == 'output_text' then
          if type(part.text) ~= 'string' then return nil, 'Malformed text from Copilot Responses' end
          parts[#parts + 1] = part.text
        elseif part.type == 'refusal' then
          if type(part.refusal) ~= 'string' then return nil, 'Malformed refusal from Copilot Responses' end
          parts[#parts + 1] = part.refusal
        end
      end
      if #parts > 0 then texts[#texts + 1] = table.concat(parts) end
    elseif item.type == 'function_call' then
      if type(item.call_id) ~= 'string' or item.call_id == ''
        or type(item.name) ~= 'string' or item.name == '' or type(item.arguments) ~= 'string' then
        return nil, 'Malformed tool call from Copilot Responses'
      end
      calls[#calls + 1] = {
        id = item.call_id, type = 'function', ['function'] = { name = item.name, arguments = item.arguments },
      }
    elseif item.type == 'reasoning' and type(item.encrypted_content) == 'string' then
      reasoning[#reasoning + 1] = item
    end
  end
  if #texts == 0 and #calls == 0 then return nil, 'Response has no assistant message' end
  return {
    role = 'assistant', content = #texts > 0 and table.concat(texts, '\n') or vim.NIL,
    tool_calls = #calls > 0 and calls or nil,
    _copilot_reasoning = #reasoning > 0 and reasoning or nil,
  }
end

return M
