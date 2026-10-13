local M = {}

-- Assemble SSE events into the same response shapes used by the non-streaming adapters.
function M.new(responses, on_text, on_activity)
  local pending, headers, sse = '', true, false
  local failure, completed, result, usage, finish_reason
  local message = { role = 'assistant', content = '' }
  local calls, reasoning = {}, {}
  local preview = ''
  local function text(value)
    if type(value) ~= 'string' then error('Invalid streaming text') end
    preview = preview .. value
    on_text(preview)
  end
  local function event(data)
    if data == '[DONE]' then
      if not responses then completed = true end
      return
    end
    local value = vim.json.decode(data)
    if type(value) ~= 'table' then error('Invalid streaming event') end
    if value.error or value.type == 'error' then
      local err = type(value.error) == 'table' and value.error.message or value.message or value.error
      error(tostring(err or 'Provider streaming error'))
    end
    if responses then
      if value.type == 'response.output_text.delta' or value.type == 'response.refusal.delta' then
        text(value.delta)
      elseif value.type == 'response.completed' or value.type == 'response.failed'
        or value.type == 'response.incomplete' then
        if type(value.response) ~= 'table' then error('Invalid terminal Responses event') end
        result, completed = value.response, true
      end
      return
    end
    if type(value.usage) == 'table' then usage = value.usage end
    local choice = type(value.choices) == 'table' and value.choices[1]
    if not choice then return end
    if type(choice) ~= 'table' then error('Invalid streaming choice') end
    if choice.index ~= nil and choice.index ~= 0 then return end
    if choice.finish_reason ~= nil and choice.finish_reason ~= vim.NIL then finish_reason = choice.finish_reason end
    local delta = choice.delta
    if delta == nil or delta == vim.NIL then return end
    if type(delta) ~= 'table' then error('Invalid streaming delta') end
    if delta.content ~= nil and delta.content ~= vim.NIL then
      text(delta.content)
      message.content = message.content .. delta.content
    end
    if delta.refusal ~= nil and delta.refusal ~= vim.NIL then
      if type(delta.refusal) ~= 'string' then error('Invalid streaming refusal') end
      message.refusal = (message.refusal or '') .. delta.refusal
      if message.content == '' then text(delta.refusal) end
    end
    if delta.tool_calls ~= nil and delta.tool_calls ~= vim.NIL then
      if type(delta.tool_calls) ~= 'table' then error('Invalid streaming tool calls') end
      for _, call in ipairs(delta.tool_calls) do
        if type(call) ~= 'table' or type(call.index) ~= 'number' or call.index < 0
          or call.index % 1 ~= 0 then error('Invalid streaming tool index') end
        local target = calls[call.index] or { type = 'function', ['function'] = { name = '', arguments = '' } }
        calls[call.index] = target
        if call.id then target.id = call.id end
        if call.type then target.type = call.type end
        if call['function'] ~= nil then
          if type(call['function']) ~= 'table' then error('Invalid streaming function') end
          for _, key in ipairs({ 'name', 'arguments' }) do
            local part = call['function'][key]
            if part ~= nil then
              if type(part) ~= 'string' then error('Invalid streaming function ' .. key) end
              target['function'][key] = target['function'][key] .. part
            end
          end
        end
      end
    end
    if type(delta.reasoning_details) == 'table' then
      for _, detail in ipairs(delta.reasoning_details) do
        if type(detail) ~= 'table' then error('Invalid streaming reasoning') end
        local index = detail.index or #reasoning
        local target = reasoning[index] or {}
        reasoning[index] = target
        for key, part in pairs(detail) do
          if (key == 'text' or key == 'summary' or key == 'data') and type(part) == 'string' then
            target[key] = (target[key] or '') .. part
          else target[key] = part end
        end
      end
    end
  end
  local function consume(chunk)
    pending = pending .. chunk:gsub('\r\n', '\n')
    -- A CRLF can be split across stdout callbacks; normalize once both bytes arrive.
    pending = pending:gsub('\r\n', '\n')
    while true do
      local boundary = pending:find('\n\n', 1, true)
      if not boundary then return end
      local block = pending:sub(1, boundary - 1)
      pending = pending:sub(boundary + 2)
      if headers then
        if not block:match('^HTTP/%S+ %d%d%d') then error('Invalid streaming HTTP headers') end
        local status = tonumber(block:match('^HTTP/%S+ (%d%d%d)'))
        if status >= 200 and not block:match('^[^\n]*[Cc]onnection established') then
          headers = false
          sse = status < 300 and block:lower():find('content%-type:%s*text/event%-stream') ~= nil
        end
      elseif sse then
        local data = {}
        for line in (block .. '\n'):gmatch('(.-)\n') do
          if line:sub(1, 5) == 'data:' then data[#data + 1] = line:sub(6):gsub('^ ', '') end
        end
        if #data > 0 then
          event(table.concat(data, '\n'))
          if on_activity then on_activity() end
        end
      end
    end
  end
  return {
    push = function(chunk)
      if failure then return end
      local ok, err = pcall(consume, chunk)
      if not ok then failure = 'Invalid streaming response: ' .. tostring(err) end
    end,
    finish = function()
      if not sse then return nil, nil, false end
      if failure then return nil, failure, true end
      if not completed then return nil, 'Streaming response ended before completion', true end
      if responses then return result, nil, true end
      local function ordered(values)
        local keys = vim.tbl_keys(values)
        table.sort(keys)
        local list = {}
        for _, key in ipairs(keys) do list[#list + 1] = values[key] end
        return #list > 0 and list or nil
      end
      message.tool_calls, message.reasoning_details = ordered(calls), ordered(reasoning)
      if message.content == '' and not message.refusal and not message.tool_calls then
        return nil, 'Response has no assistant message', true
      end
      return { choices = { { message = message, finish_reason = finish_reason } }, usage = usage }, nil, true
    end,
  }
end

return M
