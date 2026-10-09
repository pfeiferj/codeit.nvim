local M = {}
local agent_tools = require('codeit.agent_tools')
local approval = require('codeit.approval')
local file_buffer = require('codeit.file_buffer')

local gated = { edit_file = true, create_file = true,
  run_command = true, fetch_url = true }

function M.configure(opts)
  approval.setup(opts)
end

M.specs = {
  {
    type = 'function',
    ['function'] = {
      name = 'list_buffers',
      description = 'List loaded ordinary workspace buffers plus the source buffer, including an unnamed source. Returns IDs, names, modified and source flags. Unrelated buffers are hidden by default; include_external=true explicitly lists all ordinary buffers subject to approval.',
      parameters = { type = 'object', properties = {
        include_external = { type = 'boolean', description = 'Include unrelated and unnamed buffers (default false)' },
      } },
    },
  },
}

vim.list_extend(M.specs, agent_tools.specs)
M.specs[#M.specs + 1] = {
  type = 'function', ['function'] = {
    name = 'load_skill',
    description = 'Load instructions for an available skill by name. Select a skill when its description matches the task.',
    parameters = { type = 'object', properties = { name = { type = 'string' } }, required = { 'name' } },
  },
}

for _, definition in ipairs(M.specs) do
  definition['function'].parameters.additionalProperties = false
end

function M.request_specs(workspace, mode)
  for _, entry in ipairs(require('codeit.context_files').entries(workspace, mode)) do
    if entry.kind == 'skill' and entry.available then return M.specs end
  end
  local specs = {}
  for _, definition in ipairs(M.specs) do
    if definition['function'].name ~= 'load_skill' then specs[#specs + 1] = definition end
  end
  return specs
end

local execute_approved

function M.validate(name, args)
  if type(name) ~= 'string' or type(args) ~= 'table' or vim.islist(args) and #args > 0 then
    return 'tool name must be a string and arguments must be an object'
  end
  for _, definition in ipairs(M.specs) do
    local fn = definition['function']
    if fn.name == name then
      for _, key in ipairs(fn.parameters.required or {}) do
        if args[key] == nil then return 'missing argument ' .. key end
      end
      for key, value in pairs(args) do
        local property = fn.parameters.properties[key]
        if not property then return 'unknown argument ' .. tostring(key) end
        local kind = property.type
        if kind == 'integer' then
          if type(value) ~= 'number' or value == math.huge or value % 1 ~= 0
            or value < (property.minimum or 0) then return key .. ' must be a valid integer' end
        elseif kind == 'array' then
          if type(value) ~= 'table' or not vim.islist(value) then return key .. ' must be an array' end
        elseif type(value) ~= kind then return key .. ' must be a ' .. kind end
      end
      if name == 'read_file' or name == 'edit_file' then
        if args.path ~= nil and args.buffer_id ~= nil then return 'specify path OR buffer_id, not both' end
        if name == 'edit_file' and (args.start_line == nil) ~= (args.end_line == nil) then
          return 'edit range requires both start_line and end_line'
        end
      end
      return
    end
  end
  return 'unknown tool ' .. name .. '; use the advertised tools (read_file/edit_file accept buffer_id)'
end

--- Execute a tool and call done(result_string, optional_cancel_signal).
function M.execute(name, args, source, done, active, context)
  local completed, callback = false, done
  done = function(...)
    if completed or active and not active() then return end
    completed = true
    callback(...)
  end
  local function safe(action)
    return function(...)
      if completed or active and not active() then return end
      local ok, err = pcall(action, ...)
      if not ok then done('Error: tool execution failed: ' .. tostring(err)) end
    end
  end
  return safe(function()
    -- Validate before approval and editor API calls.
    local invalid = M.validate(name, args)
    if invalid then return done('Error: ' .. invalid) end
    if name == 'load_skill' then
      local workspace = require('codeit.history').workspace()
      if not require('codeit.context_files').skill(args.name, workspace, approval.workspace_trust(workspace)) then
        return done('Error: skill is not available, is disabled, or workspace is not trusted')
      end
    end
    local reads = context and context.read_versions
    local function prepare(path)
      return not context or not context.prepare or context.prepare(path)
    end
    local function gate(prompt, action, diff)
      local request_context = vim.tbl_extend('force', context or {}, { source_buffer = source })
      request_context.diff = diff
      return approval.request(name, args, prompt, active, done, safe(function()
        if diff and not prepare(diff.path) then
          return done('Error: project instructions changed while awaiting approval; review them before reissuing this write')
        end
        action()
      end), request_context)
    end
    if not gated[name] then
      return gate('Allow ' .. tostring(name) .. ' ' .. vim.json.encode(args) .. '?', function()
        execute_approved(name, args, source, done, active, gate, reads, prepare)
      end)
    end
    return execute_approved(name, args, source, done, active, gate, reads, prepare)
  end)()
end

execute_approved = function(name, args, source, done, active, gate, reads, prepare)
  if name == 'list_buffers' then
    return done(vim.json.encode(file_buffer.list(source, args.include_external)))
  end
  if name == 'load_skill' then
    local workspace = require('codeit.history').workspace()
    local skill = require('codeit.context_files').skill(args.name, workspace,
      approval.workspace_trust(workspace))
    return done(skill and ('Skill ' .. args.name .. ' (' .. skill.path .. '):\n' .. skill.content)
      or 'Error: skill is not available or workspace is not trusted')
  end
  return agent_tools.execute(name, args, done, active, gate, reads, prepare, source)
end

return M
