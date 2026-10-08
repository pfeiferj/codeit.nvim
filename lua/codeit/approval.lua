local M = {}
local approval_prompt = require('codeit.approval_prompt')

local read_tools = {
  list_buffers = true, read_buffer = true, list_workspace_files = true,
  search_workspace = true, read_file = true, get_diagnostics = true,
  git_status = true, git_diff = true,
}

local trusted_workspaces = {}
local saved_trust
local trust_path

local function within(path, base)
  return path == base or path:sub(1, #base + 1) == base .. '/'
end

local function trusted_path(path, workspace)
  if type(path) ~= 'string' or path == '' or path:find('\0', 1, true) then return nil end
  local absolute = path:sub(1, 1) == '/' and path or workspace .. '/' .. path
  local real = vim.uv.fs_realpath(absolute)
  local stat = real and vim.uv.fs_stat(real)
  if stat and stat.type == 'file' and within(real, workspace) then return real end
end

local function tracked(path, workspace)
  local relative = path:sub(#workspace + 2)
  local ok, result = pcall(function()
    return vim.system({ 'git', '-C', workspace, 'ls-files', '--error-unmatch', '--', relative },
      { text = true }):wait()
  end)
  return ok and result.code == 0
end

local function buffer_path(id)
  if type(id) ~= 'number' or not vim.api.nvim_buf_is_valid(id) or not vim.api.nvim_buf_is_loaded(id)
    or vim.bo[id].buftype ~= '' then return nil end
  return vim.api.nvim_buf_get_name(id)
end

local function auto_read(name, args, workspace, source)
  local mode = M.workspace_trust(workspace)
  if not mode or not read_tools[name] then return false end
  local function allowed(path)
    local real = trusted_path(path, workspace)
    return real and (mode == 'all' or tracked(real, workspace)) or false
  end
  if name == 'read_file' or name == 'read_buffer' then
    if name == 'read_file' then return allowed(args.path) end
    return allowed(buffer_path(args.buffer_id or source))
  end
  if name == 'list_buffers' then
    for _, id in ipairs(vim.api.nvim_list_bufs()) do
      local path = buffer_path(id)
      if path and path ~= '' and not allowed(path) then return false end
    end
    return true
  end
  if name == 'git_diff' then return args.path == nil or allowed(args.path) end
  if name == 'get_diagnostics' then
    return args.path ~= nil and allowed(args.path) or args.path == nil and mode == 'all'
  end
  -- Workspace-wide listing and searching can expose untracked files. Git status
  -- also reports untracked names; only auto-approve these in all-files mode.
  return mode == 'all'
end

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
  trusted_workspaces = {}
  for path, mode in pairs(opts.trusted_workspaces or {}) do
    if type(path) ~= 'string' or path:sub(1, 1) ~= '/' or (mode ~= 'all' and mode ~= 'tracked') then
      error("codeit: approval.trusted_workspaces must map absolute directories to 'all' or 'tracked'")
    end
    local real = vim.uv.fs_realpath(path)
    if not real or not vim.uv.fs_stat(real) or vim.uv.fs_stat(real).type ~= 'directory' then
      error('codeit: trusted workspace does not exist: ' .. path)
    end
    trusted_workspaces[real] = mode
  end
  remembered = nil
  saved_trust = nil
end

local function load_trust()
  if saved_trust then return end
  trust_path = vim.fn.stdpath('data') .. '/codeit/trusted_workspaces.json'
  saved_trust = {}
  local file = io.open(trust_path, 'r')
  if not file then return end
  local text = file:read('*a')
  file:close()
  local ok, data = pcall(vim.json.decode, text)
  if not ok or type(data) ~= 'table' then return end
  for path, mode in pairs(data) do
    if type(path) == 'string' and path:sub(1, 1) == '/'
      and (mode == 'all' or mode == 'tracked' or mode == false) then
      saved_trust[path] = mode
    end
  end
end

--- Return the effective trust mode for a resolved workspace (or the current cwd).
function M.workspace_trust(workspace)
  load_trust()
  workspace = workspace or vim.uv.fs_realpath(vim.fn.getcwd())
  if not workspace then return nil end
  if saved_trust[workspace] ~= nil then return saved_trust[workspace] or nil end
  return trusted_workspaces[workspace]
end

--- Persist trust for the current workspace. nil revokes trust, including configured trust.
function M.set_workspace_trust(mode, workspace)
  if mode ~= nil and mode ~= 'all' and mode ~= 'tracked' then
    return false, 'Expected all or tracked'
  end
  workspace = workspace or vim.uv.fs_realpath(vim.fn.getcwd())
  if not workspace then return false, 'Workspace does not exist' end
  load_trust()
  local updated = vim.tbl_extend('force', {}, saved_trust, { [workspace] = mode or false })
  vim.fn.mkdir(vim.fn.fnamemodify(trust_path, ':h'), 'p')
  local temp_path = trust_path .. '.tmp.' .. vim.fn.getpid() .. '.' .. vim.uv.hrtime()
  local fd, err = vim.uv.fs_open(temp_path, 'wx', 384) -- 0600
  if not fd then return false, tostring(err) end
  local data = vim.json.encode(updated)
  local written, write_err = vim.uv.fs_write(fd, data, 0)
  vim.uv.fs_close(fd)
  if written ~= #data then
    vim.uv.fs_unlink(temp_path)
    return false, tostring(write_err or 'Incomplete write')
  end
  local renamed, rename_err = vim.uv.fs_rename(temp_path, trust_path)
  if not renamed then
    vim.uv.fs_unlink(temp_path)
    return false, tostring(rename_err)
  end
  saved_trust = updated
  return true
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
  if verdict == 'approve' or (verdict ~= 'ask' and (remembered[signature]
    or auto_read(name, args, workspace, context.source_buffer))) then return action() end

  local function live() return not active or active() end
  local choose
  local function review(history)
    if not context.review then return choose() end
    approval_prompt.ask_reviewer(name, canonical(args), function(question)
      if not live() then return end
      if not question or vim.trim(question) == '' then return choose() end
      history[#history + 1] = { role = 'user', content = question }
      context.review(history, function(answer, err)
        if not live() then return end
        if err then answer = 'Reviewer error: ' .. tostring(err) end
        history[#history + 1] = { role = 'assistant', content = answer or '' }
        approval_prompt.show('Question: ' .. question .. '\n\nReviewer: ' .. (answer or ''), {
          { key = '1', id = 'again', label = 'Ask another question' },
          { key = '2', id = 'back', label = 'Back to approval' },
        }, function(choice)
          if not live() then return end
          if choice == 'again' then review(history) else choose() end
        end, { title = ' Tool-call reviewer ', dismiss = 'Back to approval' })
      end)
    end)
  end
  choose = function()
    if not live() then return end
    local options = {
      { key = '1', id = 'once', label = 'Approve once' },
      { key = '2', id = 'always', label = 'Always approve exact call' },
      { key = '3', id = 'reject', label = 'Reject (optional reason)' },
      { key = '4', id = 'cancel', label = 'Cancel task' },
    }
    if read_tools[name] then
      options[#options + 1] = { key = '5', id = 'tracked', label = 'Trust workspace (Git-tracked reads)' }
      options[#options + 1] = { key = '6', id = 'all', label = 'Trust workspace (all reads)' }
    end
    if context.review then options[#options + 1] = { key = tostring(#options + 1), id = 'review', label = 'Ask reviewer' } end
    approval_prompt.show(prompt .. (reason and '\n' .. tostring(reason) or '') .. '\nWorkspace: ' .. workspace,
      options, function(choice)
      if not live() then return end
      if choice == 'once' then return action() end
      if choice == 'always' then
        remembered[signature] = true
        persist()
        return action()
      end
      if choice == 'tracked' or choice == 'all' then
        local ok, err = M.set_workspace_trust(choice, workspace)
        if not ok then
          vim.notify('codeit: could not save workspace trust: ' .. tostring(err), vim.log.levels.ERROR)
          return choose()
        end
        return action()
      end
      if choice == 'cancel' then return done('Cancelled by user', 'cancel') end
      if choice == 'review' then
        return review({ { role = 'system', content = 'You are an independent tool-call reviewer. Analyze safety and implications of the proposed tool call. Do not use tools or carry out the action. Answer the user concisely.' },
          { role = 'user', content = 'User request: ' .. tostring(context.user_request or '') .. '\nTool: ' .. name .. '\nArguments: ' .. canonical(args) .. '\nApproval prompt: ' .. prompt } })
      end
      if choice ~= 'reject' then return done('Rejected by user') end
      vim.ui.input({ prompt = 'Reason for rejecting (optional): ' }, function(instruction)
        if not live() then return end
        done('Rejected by user' .. (instruction and vim.trim(instruction) ~= '' and ': ' .. instruction or ''))
      end)
    end)
  end
  choose()
end

return M
