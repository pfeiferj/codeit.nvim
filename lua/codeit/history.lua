local M = {}

local function directory(workspace)
  return vim.fn.stdpath('data') .. '/codeit/chats/' .. vim.fn.sha256(workspace)
end

function M.workspace()
  return vim.uv.fs_realpath(vim.fn.getcwd()) or vim.fn.fnamemodify(vim.fn.getcwd(), ':p'):gsub('/$', '')
end

function M.new_id()
  -- tostring() uses scientific notation for large clocks, which path() rejects.
  return tostring(os.time()) .. '-' .. string.format('%.0f', vim.uv.hrtime())
end

local function path(workspace, id)
  if type(id) ~= 'string' or not id:match('^[%w%-]+$') then return nil end
  return directory(workspace) .. '/' .. id .. '.json'
end

function M.save(workspace, id, chat, opts)
  local filename = path(workspace, id)
  if not filename then return false, 'invalid chat id' end
  local dir = directory(workspace)
  if vim.fn.mkdir(dir, 'p') == 0 and vim.fn.isdirectory(dir) == 0 then return false, 'cannot create chat directory' end
  vim.uv.fs_chmod(dir, 448) -- 0700
  -- Preserve the cache on ordinary saves, but invalidate it when the user
  -- continues the conversation with a new question.
  if not (opts and opts.clear_summary) then
    local previous = M.load(workspace, id)
    if previous and type(previous.summary) == 'string' and previous.summary ~= '' then
      chat = vim.tbl_extend('force', chat, { summary = previous.summary })
    end
  end
  local ok, data = pcall(vim.json.encode, vim.tbl_extend('force', chat, { workspace = workspace, id = id }))
  if not ok then return false, data end
  local temporary = filename .. '.' .. tostring(vim.uv.hrtime()) .. '.tmp'
  local fd, err = vim.uv.fs_open(temporary, 'w', 384) -- 0600
  if not fd then return false, err end
  vim.uv.fs_chmod(temporary, 384)
  local written, write_err = vim.uv.fs_write(fd, data, 0)
  vim.uv.fs_close(fd)
  if written ~= #data then
    vim.uv.fs_unlink(temporary)
    return false, write_err or 'incomplete write'
  end
  local renamed, rename_err = vim.uv.fs_rename(temporary, filename)
  if not renamed then vim.uv.fs_unlink(temporary); return false, rename_err end
  return true
end

function M.load(workspace, id)
  local filename = path(workspace, id)
  if not filename then return nil, 'invalid chat id' end
  local file = io.open(filename, 'r')
  if not file then return nil, 'chat not found' end
  local text = file:read('*a')
  file:close()
  local ok, chat = pcall(vim.json.decode, text)
  if not ok or type(chat) ~= 'table' or chat.workspace ~= workspace or chat.id ~= id
    or type(chat.messages) ~= 'table' or not vim.islist(chat.messages)
    or (chat.provider ~= 'openrouter' and chat.provider ~= 'copilot') or type(chat.model) ~= 'string' then
    return nil, 'invalid chat file'
  end
  for _, message in ipairs(chat.messages) do
    if type(message) ~= 'table' or not vim.tbl_contains({ 'system', 'user', 'assistant', 'tool' }, message.role) then
      return nil, 'invalid chat messages'
    end
  end
  -- A process may have stopped halfway through a tool batch. Never send an
  -- unmatched assistant tool call (or a partial batch) back to the provider.
  for i = #chat.messages, 1, -1 do
    local message = chat.messages[i]
    if message.role == 'assistant' and type(message.tool_calls) == 'table' and #message.tool_calls > 0 then
      local results = {}
      for j = i + 1, #chat.messages do
        local result = chat.messages[j]
        if result.role == 'tool' then results[result.tool_call_id] = true end
      end
      local complete = true
      for _, call in ipairs(message.tool_calls) do
        if not results[call.id] then complete = false; break end
      end
      if not complete then
        for j = #chat.messages, i, -1 do table.remove(chat.messages, j) end
      end
      break
    end
  end
  -- Older chats have no command results. Ignore malformed display-only data,
  -- and re-anchor results if an interrupted tool batch was removed above.
  local command_results = {}
  if type(chat.command_results) == 'table' and vim.islist(chat.command_results) then
    for _, result in ipairs(chat.command_results) do
      local index = type(result) == 'table' and result.after_message
      if type(result) == 'table' and type(result.command) == 'string' and type(result.output) == 'string'
        and type(index) == 'number' and index >= 0 and index < math.huge and index == math.floor(index) then
        command_results[#command_results + 1] = {
          command = result.command, output = result.output, after_message = math.min(index, #chat.messages),
        }
      end
    end
  end
  chat.command_results = command_results
  -- Never skip messages unless the saved checkpoint still covers a complete turn.
  local cutoff = chat.compacted_until
  local checkpoint = type(cutoff) == 'number' and cutoff == math.floor(cutoff)
    and cutoff >= 3 and cutoff <= #chat.messages and chat.messages[cutoff] or nil
  if type(chat.context_summary) ~= 'string' or chat.context_summary == '' or not checkpoint
    or checkpoint.role ~= 'assistant'
    or (type(checkpoint.tool_calls) == 'table' and #checkpoint.tool_calls > 0) then
    chat.context_summary, chat.compacted_until = nil, nil
  end
  return chat
end

function M.delete(workspace, id)
  local filename = path(workspace, id)
  if not filename then return false, 'invalid chat id' end
  return vim.uv.fs_unlink(filename)
end

function M.set_summary(workspace, id, summary)
  local chat, err = M.load(workspace, id)
  if not chat then return false, err end
  if type(chat.summary) == 'string' and chat.summary ~= '' then return true end
  if type(summary) ~= 'string' or summary == '' then return false, 'invalid summary' end
  chat.summary = summary
  return M.save(workspace, id, chat)
end

function M.list(workspace)
  local dir = directory(workspace)
  local entries = {}
  local handle = vim.uv.fs_scandir(dir)
  if not handle then return entries end
  while true do
    local name, kind = vim.uv.fs_scandir_next(handle)
    if not name then break end
    if kind == 'file' then
      local id = name:match('^([%w%-]+)%.json$')
      if id then
        local chat = M.load(workspace, id)
        if chat then entries[#entries + 1] = chat end
      end
    end
  end
  table.sort(entries, function(a, b)
    if a.updated_at == b.updated_at then return a.id > b.id end
    return (tonumber(a.updated_at) or 0) > (tonumber(b.updated_at) or 0)
  end)
  return entries
end

return M
