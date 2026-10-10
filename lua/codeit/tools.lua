local M = {}
local agent_tools = require('codeit.agent_tools')
local window_tools = require('codeit.window_tools')
local approval = require('codeit.approval')
local file_buffer = require('codeit.file_buffer')
local tool_log = require('codeit.tool_log')

local gated = { edit_file = true, edit_loaded_buffer = true, edit_source_buffer = true,
  create_file = true, save_buffer = true, save_loaded_buffer = true, save_source_buffer = true,
  run_command = true, start_background_task = true, fetch_url = true }

function M.configure(opts)
  approval.setup(opts)
end

M.specs = {
  {
    type = 'function',
    ['function'] = {
      name = 'list_buffers',
      description = 'List loaded ordinary workspace buffers. Returns IDs, names, modified and source flags. External and unnamed buffers, including the source, are hidden by default; include_external=true explicitly lists all ordinary buffers subject to approval.',
      parameters = { type = 'object', properties = {
        include_external = { type = 'boolean', description = 'Include unrelated and unnamed buffers (default false)' },
      } },
    },
  },
}

M.specs[#M.specs + 1] = {
  type = 'function', ['function'] = {
    name = 'ask_user',
    description = 'Pause for a necessary clarification, displayed in a near-full-screen popup. Questions may contain multiple lines. Ask only when inspecting the project cannot resolve it. Optional choices (up to 10) plus a multiline free-text answer. Dismissal cancels the task; never treat this answer as approval to write or save.',
    parameters = { type = 'object', properties = {
      question = { type = 'string', minLength = 1, maxLength = 2000 },
      choices = { type = 'array', maxItems = 10, items = { type = 'string', minLength = 1, maxLength = 200 } },
    }, required = { 'question' } },
  },
}
vim.list_extend(M.specs, agent_tools.specs)
vim.list_extend(M.specs, window_tools.specs)
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

local function normalize_optional(value, schema)
  if type(value) ~= 'table' then return end
  if schema.type == 'object' then
    for key, property in pairs(schema.properties or {}) do
      -- Normalize before validation so approvals and execution see the same defaults.
      if value[key] == '' and not vim.tbl_contains(schema.required or {}, key) then
        value[key] = nil
      elseif value[key] ~= nil then
        normalize_optional(value[key], property)
      end
    end
  elseif schema.type == 'array' and schema.items then
    for _, item in ipairs(value) do normalize_optional(item, schema.items) end
  end
end

local function validate_value(value, property, key)
  local kind = property.type
  if kind == 'integer' then
    if type(value) ~= 'number' or value == math.huge or value % 1 ~= 0
      or value < (property.minimum or 0) or property.maximum and value > property.maximum then
      return key .. ' must be a valid integer'
    end
  elseif kind == 'array' then
    if type(value) ~= 'table' or not vim.islist(value) then return key .. ' must be an array' end
    if #value < (property.minItems or 0) or property.maxItems and #value > property.maxItems then
      return key .. ' has invalid number of items'
    end
    if property.items then
      for index, item in ipairs(value) do
        local err = validate_value(item, property.items, key .. '[' .. index .. ']')
        if err then return err end
      end
    end
  elseif kind == 'object' then
    if type(value) ~= 'table' or vim.islist(value) and #value > 0 then return key .. ' must be an object' end
    for _, required in ipairs(property.required or {}) do
      if value[required] == nil then return key .. ': missing argument ' .. required end
    end
    for field, item in pairs(value) do
      local child = property.properties[field]
      if not child then return key .. ': unknown argument ' .. tostring(field) end
      local err = validate_value(item, child, key .. '.' .. field)
      if err then return err end
    end
  elseif type(value) ~= kind then return key .. ' must be a ' .. kind end
  if kind == 'string' and (#value < (property.minLength or 0) or property.maxLength and #value > property.maxLength) then
    return key .. ' has invalid length'
  end
end

function M.validate(name, args)
  if type(name) ~= 'string' or type(args) ~= 'table' or vim.islist(args) and #args > 0 then
    return 'tool name must be a string and arguments must be an object'
  end
  for _, definition in ipairs(M.specs) do
    local fn = definition['function']
    if fn.name == name then
      normalize_optional(args, fn.parameters)
      for _, key in ipairs(fn.parameters.required or {}) do
        if args[key] == nil then return 'missing argument ' .. key end
      end
      for key, value in pairs(args) do
        local property = fn.parameters.properties[key]
        if not property then return 'unknown argument ' .. tostring(key) end
        local err = validate_value(value, property, tostring(key))
        if err then return err end
      end
      if name == 'edit_file' or name == 'edit_loaded_buffer' or name == 'edit_source_buffer' then
        local total = 0
        for _, edit in ipairs(args.edits) do
          if (edit.start_line == nil) ~= (edit.end_line == nil) then return 'edit range requires both start_line and end_line' end
          if edit.end_line and edit.end_line < edit.start_line then return 'invalid edit range' end
          if edit.old_text == '' then return 'old_text must be nonempty' end
          total = total + #edit.old_text + #edit.new_text
        end
        if total > 200000 then return 'replacement text must total at most 200KB' end
      end
      if name == 'ask_user' then
        if vim.trim(args.question) == '' or args.question:gsub('[\n\r\t]', ''):find('%c') then
          return 'question must be nonempty text without unsupported control characters'
        end
        for _, choice in ipairs(args.choices or {}) do
          if vim.trim(choice) == '' or choice:find('%c') then return 'choices must be nonempty single-line text' end
        end
      end
      return
    end
  end
  return 'unknown tool ' .. name .. '; use the advertised tools (read_loaded_buffer accepts buffer_id)'
end

--- Execute a tool and call done(result_string, optional_cancel_signal).
function M.execute(name, args, source, done, active, context)
  local completed, callback = false, done
  local entry = context and context.tool_log_entry or tool_log.start(name, args)
  done = function(result, signal)
    if completed or active and not active() then return end
    completed = true
    tool_log.finish(entry, result, signal)
    callback(result, signal)
  end
  local function safe(action)
    return function(...)
      if completed or active and not active() then return end
      local ok, err = pcall(require('codeit.managed_tab').assistant, action, ...)
      if not ok then done('Error: tool execution failed: ' .. tostring(err)) end
    end
  end
  return safe(function()
    -- Validate before approval and editor API calls.
    local invalid = M.validate(name, args)
    if invalid then return done('Error: ' .. invalid) end
    local visible = name == 'read_window_buffer' and require('codeit.managed_tab').buffer(args.window_id)
    if name == 'read_window_buffer' and not visible then return done('Error: invalid Codeit file window') end
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
        if visible and require('codeit.managed_tab').buffer(args.window_id) ~= visible then
          return done('Error: window buffer changed while awaiting approval; reissue the read')
        end
        execute_approved(name, args, source, done, active, gate, reads, prepare, context and context.background_origin)
      end)
    end
    return execute_approved(name, args, source, done, active, gate, reads, prepare, context and context.background_origin)
  end)()
end

execute_approved = function(name, args, source, done, active, gate, reads, prepare, origin)
  if window_tools.names[name] then return window_tools.execute(name, args, done, reads) end
  if name == 'ask_user' then
    require('codeit.question_prompt').show(args.question, args.choices, function(answer)
      if answer == nil then return done('Cancelled by user', 'cancel') end
      done(vim.json.encode({ answer = answer }))
    end)
    return
  end
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
  return agent_tools.execute(name, args, done, active, gate, reads, prepare, source, origin)
end

return M
