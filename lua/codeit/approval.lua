local M = {}

local safe = {
  list_buffers = true, read_buffer = true, list_workspace_files = true,
  search_workspace = true, read_file = true, get_diagnostics = true,
  git_status = true, git_diff = true,
}

local validators = {}
local remembered
local store_path

local function canonical(value)
  if type(value) ~= 'table' then return vim.json.encode(value) end
  if vim.islist(value) then
    local parts = {}
    for _, item in ipairs(value) do parts[#parts + 1] = canonical(item) end
    return '[' .. table.concat(parts, ',') .. ']'
  end
  local keys, parts = {}, {}
  for key in pairs(value) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do parts[#parts + 1] = vim.json.encode(key) .. ':' .. canonical(value[key]) end
return '{' .. table.concat(parts, ',') .. '}'
end

local function load()
  if remembered then return end
  store_path = vim.fn.stdpath('data') .. '/codeit/approvals.json'
  remembered = {}
  local file = io.open(store_path, 'r')
  if not file then return end
  local text = file:read('*a')
  file:close()
  local ok, data = pcall(vim.json.decode, text)
  if ok and type(data) == 'table' then remembered = data end
end

local function persist()
  vim.fn.mkdir(vim.fn.fnamemodify(store_path, ':h'), 'p')
  local fd, err = vim.uv.fs_open(store_path, 'w', 384) -- 0600
  if not fd then vim.notify('codeit: could not save approvals: ' .. tostring(err), vim.log.levels.ERROR); return end
  vim.uv.fs_chmod(store_path, 384)
  local data = vim.json.encode(remembered)
  local written, write_err = vim.uv.fs_write(fd, data, 0)
  vim.uv.fs_close(fd)
  if written ~= #data then vim.notify('codeit: could not save approvals: ' .. tostring(write_err), vim.log.levels.ERROR) end
end

--- Validators receive (name, args, context) and return 'approve', 'ask', 'reject',
--- or nil, optionally followed by a reason. Reject wins over ask, which wins over approve.
--- A validator error fails closed. Context includes workspace and the current user request.
function M.setup(opts)
  opts = opts or {}
  validators = opts.validators or {}
  if type(validators) ~= 'table' then error('codeit: approval.validators must be a list') end
  for _, validator in ipairs(validators) do
    if type(validator) ~= 'function' then error('codeit: approval validators must be functions') end
  end
  remembered = nil
end

function M.request(name, args, prompt, active, done, action, context)
  context = context or {}
  load()
  local workspace = vim.uv.fs_realpath(vim.fn.getcwd()) or vim.fn.getcwd()
local signature = vim.fn.sha256(canonical({ workspace = workspace, name = name, args = args }))
  local verdict, reason
  for _, validator in ipairs(validators) do
    local ok, decision, message = pcall(validator, name, args, { workspace = workspace, user_request = context.user_request })
    if not ok then decision, message = 'reject', 'Validator error: ' .. tostring(decision) end
    if decision ~= nil and decision ~= 'approve' and decision ~= 'ask' and decision ~= 'reject' then
      decision, message = 'reject', 'Invalid validator decision'
    end
    if decision == 'reject' or (decision == 'ask' and verdict ~= 'reject')
      or (decision == 'approve' and not verdict) then verdict, reason = decision, message end
  end
  if verdict == 'reject' then return done('Rejected by approval policy' .. (reason and ': ' .. tostring(reason) or '')) end
  if verdict == 'approve' or (verdict ~= 'ask' and (remembered[signature] or safe[name])) then return action() end

  local function live() return not active or active() end
  local choose
  local function review(history)
    if not context.review then return choose() end
    vim.ui.input({ prompt = 'Ask the tool-call reviewer (empty to return): ' }, function(question)
      if not live() then return end
      if not question or vim.trim(question) == '' then return choose() end
      history[#history + 1] = { role = 'user', content = question }
      context.review(history, function(answer, err)
        if not live() then return end
        if err then answer = 'Reviewer error: ' .. tostring(err) end
        history[#history + 1] = { role = 'assistant', content = answer or '' }
        vim.ui.select({ 'Ask another question', 'Back to approval' },
          { prompt = 'Reviewer: ' .. (answer or '') }, function(choice)
            if not live() then return end
            if choice == 'Ask another question' then review(history) else choose() end
          end)
      end)
    end)
  end
  choose = function()
    if not live() then return end
    local options = { 'Approve once', 'Always approve exact call', 'Reject', 'Cancel task' }
    if context.review then options[#options + 1] = 'Ask reviewer' end
    vim.ui.select(options, { prompt = prompt .. (reason and '\n' .. tostring(reason) or '') }, function(choice)
      if not live() then return end
      if choice == 'Approve once' then return action() end
      if choice == 'Always approve exact call' then
        remembered[signature] = true
        persist()
        return action()
      end
      if choice == 'Cancel task' then return done('Cancelled by user', 'cancel') end
      if choice == 'Ask reviewer' then
        return review({ { role = 'system', content = 'You are an independent tool-call reviewer. Analyze safety and implications of the proposed tool call. Do not use tools or carry out the action. Answer the user concisely.' },
          { role = 'user', content = 'User request: ' .. tostring(context.user_request or '') .. '\nTool: ' .. name .. '\nArguments: ' .. canonical(args) .. '\nApproval prompt: ' .. prompt } })
      end
      if choice ~= 'Reject' then return done('Rejected by user') end
      vim.ui.input({ prompt = 'Reason for rejecting (optional): ' }, function(instruction)
        if not live() then return end
        done('Rejected by user' .. (instruction and vim.trim(instruction) ~= '' and ': ' .. instruction or ''))
      end)
    end)
  end
  choose()
end

return M
