local ui = require('codeit.ui')
local providers = require('codeit.providers')
local tools = require('codeit.tools')
local approval = require('codeit.approval')

local M = {}
local defaults = {
  provider = 'openrouter',
  models = { openrouter = 'openai/gpt-4o-mini', copilot = 'gpt-4o' },
  system_prompt = 'You are a Neovim coding agent. Inspect workspace files and diagnostics before editing. Use tools to make and verify changes. Tool calls may require user approval; edits to existing files stay in buffers until saved.',
  approval = { validators = {} },
  max_tool_rounds = 12,

}
local config = vim.deepcopy(defaults)
local messages = {}
local cost, missing_cost = 0, 0
local tokens_in, tokens_out, missing_in, missing_out = 0, 0, false, false
local context_tokens
local source
local busy = false
local generation = 0
local status = 'Ready. Type in the lower pane; press Enter in normal mode or Ctrl-S in insert mode to send.'

local function model()
  return config.models[config.provider] or 'unknown'
end

local function format_tokens(count, scale, suffix)
  local value = string.format('%.3f', count / scale):gsub('0+$', ''):gsub('%.$', '')
  return value .. suffix
end

local function render()
  local billing
  if config.provider == 'openrouter' then
    billing = string.format('Cost: $%.3f%s | In: %s%s | Out: %s%s | Context: %s',
      cost, missing_cost > 0 and '+' or '', format_tokens(tokens_in, 1000000, 'm'), missing_in and '+' or '',
      format_tokens(tokens_out, 1000000, 'm'), missing_out and '+' or '',
      context_tokens and format_tokens(context_tokens, 1000, 'k') or '—')
  end
  ui.render(messages, status, config.provider, model(), billing)
end

local function usage_number(value)
  local number = (type(value) == 'number' or type(value) == 'string') and tonumber(value) or nil
  if number and number >= 0 and number < math.huge then return number end
end

local function record_usage(usage, main_chat)
  if config.provider ~= 'openrouter' then return end
  local amount = usage_number(usage and usage.cost)
  if amount then cost = cost + amount else missing_cost = missing_cost + 1 end
  local input_count = usage_number(usage and usage.prompt_tokens)
  local output_count = usage_number(usage and usage.completion_tokens)
  if input_count then tokens_in = tokens_in + input_count else missing_in = true end
  if output_count then tokens_out = tokens_out + output_count else missing_out = true end
  if main_chat then
    -- Review requests contribute to totals but do not describe the main chat's context.
    context_tokens = usage_number(usage and usage.total_tokens)
      or (input_count and output_count and input_count + output_count)
  end
  render()
end

local function set_status(text)
  status = text
  render()
end

local function fail(err)
  busy = false
  set_status('Error: ' .. tostring(err))
  vim.notify('codeit: ' .. tostring(err), vim.log.levels.ERROR)
end

local function complete()
  busy = false
  set_status('Ready')
end

local function request(round, id)
  if round > config.max_tool_rounds then
    return fail('Tool call limit reached (' .. config.max_tool_rounds .. ' rounds)')
  end
  set_status('Waiting for ' .. config.provider .. '…')
  providers.chat({ provider = config.provider, model = model() }, messages, tools.specs, function(message, err, usage)
    if id ~= generation then return end
    if err then return fail(err) end
    record_usage(usage, true)
    local calls = message.tool_calls
    local batch_start = #messages + 1
    table.insert(messages, { role = 'assistant', content = message.content or vim.NIL, tool_calls = calls })
    render()
    if type(calls) ~= 'table' or #calls == 0 then return complete() end
    if round == config.max_tool_rounds then return fail('Tool call limit reached') end
    local function next_call(index)
      if id ~= generation then return end
      if index > #calls then return request(round + 1, id) end
      local call = calls[index]
      if type(call) ~= 'table' or type(call.id) ~= 'string' or type(call['function']) ~= 'table' then
        return fail('Malformed tool call from provider')
      end
      local fn = call['function']
      set_status('Tool: ' .. tostring(fn.name))
      local ok, args = pcall(vim.json.decode, fn.arguments or '{}')
      if not ok then args = nil end
      local user_request
      for i = batch_start - 1, 1, -1 do
        if messages[i].role == 'user' then user_request = messages[i].content; break end
      end
      tools.execute(fn.name, args, source, function(result, signal)
        if id ~= generation then return end
        if signal == 'cancel' then
          generation = generation + 1
          busy = false
          for i = #messages, batch_start, -1 do table.remove(messages, i) end
          return set_status('Task cancelled')
        end
        table.insert(messages, { role = 'tool', tool_call_id = call.id, content = result })
        render()
        next_call(index + 1)
      end, function() return id == generation end, {
        user_request = user_request,
        review = function(history, callback)
          providers.chat({ provider = config.provider, model = model() }, history, {}, function(message, err, usage)
            if id ~= generation then return end
            if err then return callback(nil, err) end
            record_usage(usage)
            local content = message and message.content
            if type(content) == 'table' then
              local parts = {}
              for _, part in ipairs(content) do
                if part.type == 'text' then parts[#parts + 1] = part.text or '' end
              end
              content = table.concat(parts, '\n')
            end
            callback(type(content) == 'string' and content or 'No reviewer response')
          end)
        end,
      })
    end
    next_call(1)
  end)
end

function M.send(text)
  if busy then
    vim.notify('codeit: wait for the current response', vim.log.levels.WARN)
    return
  end
  text = text or ui.take_input()
  if not text or vim.trim(text) == '' then return end
  if #messages == 0 then
    table.insert(messages, { role = 'system', content = config.system_prompt })
  end
  table.insert(messages, { role = 'user', content = text })
  busy = true
  request(0, generation)
end

function M.open()
  if not ui.is_open() then
    local current = vim.api.nvim_get_current_buf()
    if vim.bo[current].buftype == '' then source = current end
  end
  ui.open(M.send, M.close)
  render()
end

function M.close()
  ui.close()
end

function M.toggle()
  if ui.is_open() then M.close() else M.open() end
end

function M.new()
  generation = generation + 1
  busy = false
  messages = {}
  cost, missing_cost = 0, 0
  tokens_in, tokens_out, missing_in, missing_out = 0, 0, false, false
  context_tokens = nil
  status = 'New conversation'
  render()
end

function M.set_provider(name)
  if name ~= 'openrouter' and name ~= 'copilot' then
    vim.notify('codeit: provider must be openrouter or copilot', vim.log.levels.ERROR)
    return
  end
  M.new()
  config.provider = name
  render()
end

function M.setup(opts)
  config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
  tools.configure(config.approval)
  if not vim.tbl_contains({ 'openrouter', 'copilot' }, config.provider) then
    error('codeit: provider must be openrouter or copilot')
  end
  M.new()
  vim.api.nvim_create_user_command('Codeit', M.toggle, { desc = 'Toggle codeit chat', force = true })
  vim.api.nvim_create_user_command('CodeitSend', function(args)
    M.open()
    M.send(args.args ~= '' and args.args or nil)
  end, { nargs = '*', desc = 'Send a message to codeit', force = true })
  vim.api.nvim_create_user_command('CodeitNew', M.new, { desc = 'Start a new conversation', force = true })
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
    { nargs = 1, complete = function() return { 'openrouter', 'copilot' } end, force = true })
end

return M
