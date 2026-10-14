local M = {}
local approval = require('codeit.tools.approval')

function M.tasks()
  local subagents = require('codeit.tools.subagents')
  local background_tasks = require('codeit.tools.execution.tasks')
  vim.api.nvim_create_user_command('CodeitSubagents', subagents.show,
    { desc = 'View session subagents, chat logs, and cancel runs', force = true })
  local task_group = vim.api.nvim_create_augroup('codeit_background_tasks', { clear = true })
  vim.api.nvim_create_autocmd('VimLeavePre', { group = task_group, callback = subagents.shutdown })
  vim.api.nvim_create_autocmd('VimLeavePre', { group = task_group, callback = background_tasks.shutdown })
  vim.api.nvim_create_user_command('CodeitTasks', background_tasks.show,
    { desc = 'View background tasks, live logs, and cancel running tasks', force = true })
end

function M.register(api)
  local M = api
  vim.api.nvim_create_user_command('CodeitSettings', M.settings,
    { desc = 'Manage main/feature models, presets, request options, and saved settings', force = true })
  vim.api.nvim_create_user_command('Codeit', M.toggle, { desc = 'Toggle codeit chat', force = true })
  vim.api.nvim_create_user_command('CodeitSkill', function(args)
    local name, arguments = require('codeit.skills.invocation').parse(args.args)
    if not name then return vim.notify('codeit: ' .. arguments, vim.log.levels.WARN) end
    M.open()
    local ok, err = M.invoke_skill(name, arguments)
    if not ok then vim.notify('codeit: ' .. err, vim.log.levels.WARN) end
  end, { nargs = '+', desc = 'Invoke a skill with optional literal arguments', force = true })
  vim.api.nvim_create_user_command('CodeitSend', function(args)
    M.open()
    M.send(args.args ~= '' and args.args or nil)
  end, { nargs = '*', desc = 'Send a message to codeit', force = true })
  vim.api.nvim_create_user_command('CodeitStop', M.stop,
    { desc = 'Interrupt the current assistant turn', force = true })
  vim.api.nvim_create_user_command('CodeitNew', M.new, { desc = 'Start a new conversation', force = true })
  vim.api.nvim_create_user_command('CodeitCompact', function(args) M.compact(args.bang) end,
    { bang = true, desc = 'Summarize older turns (! includes the recent tail)', force = true })
  vim.api.nvim_create_user_command('CodeitContext', M.context,
    { desc = 'View the effective chat context and edit its compacted summary', force = true })
  vim.api.nvim_create_user_command('CodeitContextFiles', M.context_files,
    { desc = 'View and toggle additional context files for this chat', force = true })
  vim.api.nvim_create_user_command('CodeitContextFull', M.context_full,
    { desc = 'Edit the entire effective chat context as JSON', force = true })
  vim.api.nvim_create_user_command('CodeitSystemPrompt', M.system_prompt,
    { desc = 'Edit the system prompt for the current conversation', force = true })
  vim.api.nvim_create_user_command('CodeitAutoApprovals', M.auto_approvals,
    { desc = 'Review recorded automatic approvals and ask the reviewer questions', force = true })
  vim.api.nvim_create_user_command('CodeitCosts', M.costs,
    { desc = 'Review saved chat costs and ask questions about usage', force = true })
  vim.api.nvim_create_user_command('CodeitHistory', M.history,
    { desc = 'Browse and resume saved chats for this workspace', force = true })
  vim.api.nvim_create_user_command('CodeitWorkspaces', M.workspaces,
    { desc = 'Review known workspaces and their effective read trust', force = true })
  vim.api.nvim_create_user_command('CodeitTrust', function(args)
    local workspace = vim.uv.fs_realpath(vim.fn.getcwd())
    local function save(mode)
      if not mode then return end
      local ok, err = approval.set_workspace_trust(mode, workspace)
      if not ok then return vim.notify('codeit: could not save workspace trust: ' .. err, vim.log.levels.ERROR) end
      vim.notify('codeit: trusted ' .. workspace .. ' (' .. mode .. ')')
    end
    if args.args ~= '' then return save(args.args) end
    vim.ui.select({ 'all', 'tracked' }, {
      prompt = 'Trust workspace ' .. (workspace or vim.fn.getcwd()) .. '? (all files or Git-tracked files only)',
    }, save)
  end, { nargs = '?', complete = function() return { 'all', 'tracked' } end,
    desc = 'Trust the current workspace for reads (all or tracked)', force = true })
  vim.api.nvim_create_user_command('CodeitUntrust', function()
    local ok, err = approval.set_workspace_trust(nil)
    if not ok then return vim.notify('codeit: could not revoke workspace trust: ' .. err, vim.log.levels.ERROR) end
    vim.notify('codeit: revoked trust for ' .. vim.fn.getcwd())
  end, { desc = 'Revoke read trust for the current workspace', force = true })
  vim.api.nvim_create_user_command('CodeitTrustStatus', function()
    vim.notify('codeit: ' .. vim.fn.getcwd() .. ': ' .. (approval.workspace_trust() or 'untrusted'))
  end, { desc = 'Show trust mode for the current workspace', force = true })
  vim.api.nvim_create_user_command('CodeitProvider', function(args) M.set_provider(args.args) end,
    { nargs = 1, complete = function() return { 'openrouter', 'copilot', 'codex' } end, force = true })
end

return M
