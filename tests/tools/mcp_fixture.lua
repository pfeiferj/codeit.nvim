local function send(message)
  message.jsonrpc = '2.0'
  local line = vim.json.encode(message)
  io.write(line:sub(1, 5)); io.flush()
  io.write(line:sub(6), '\n'); io.flush()
end

local initialized = false
for line in io.lines() do
  local request = vim.json.decode(line)
  assert(request.jsonrpc == '2.0')
  local result
  if request.method == 'initialize' then
    assert(vim.json.encode(request.params.capabilities) == '{}')
    result = { protocolVersion = '2024-11-05', capabilities = { tools = { listChanged = true } } }
  elseif request.method == 'notifications/initialized' then
    initialized = true
  elseif request.method == 'tools/list' then
    assert(initialized)
    if not request.params then
      result = { tools = { { name = 'other', inputSchema = { type = 'object' } } }, nextCursor = 'more' }
    else
      assert(request.params.cursor == 'more')
      result = { tools = { { name = 'echo.test', description = 'Return input', inputSchema = {
        type = 'object', properties = { keep_in_context = { type = 'boolean' }, safety_score = { type = 'number' },
          payload = { type = 'object', additionalProperties = true } }, additionalProperties = true,
      } } } }
    end
  elseif request.method == 'tools/call' then
    assert(initialized and request.params.name == 'echo.test')
    if request.params.arguments.timeout then
      -- Leave this request pending to exercise client timeouts.
    else
      if request.params.arguments.change then send({ method = 'notifications/tools/list_changed' }) end
      result = { content = { { type = 'text', text = 'echo' } }, structuredContent = request.params.arguments,
        isError = request.params.arguments.fail == true }
    end
  else
    error('Unexpected method: ' .. tostring(request.method))
  end
  if result then send({ id = request.id, result = result }) end
end
