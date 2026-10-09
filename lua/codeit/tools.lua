local M = {}
local agent_tools = require('codeit.agent_tools')
local approval = require('codeit.approval')
local file_buffer = require('codeit.file_buffer')

local gated = { replace_buffer_lines = true, edit_file = true, create_file = true,
  run_command = true, fetch_url = true }

function M.configure(opts)
  approval.setup(opts)
end

M.specs = {
  {
    type = 'function',
    ['function'] = {
      name = 'list_buffers',
      description = 'List loaded, named Neovim buffers with their IDs and modified status.',
      parameters = { type = 'object', properties = vim.empty_dict() },
    },
  },
  {
    type = 'function',
    ['function'] = {
      name = 'read_buffer',
      description = 'Read a loaded ordinary buffer; clean files refresh from disk, unsaved changes are preserved. Defaults to the buffer active before chat opened. Lines are 1-based/inclusive; at most 200 lines/20000 encoded bytes. Returns total_lines, truncated, next_start_line, modified.',
      parameters = {
        type = 'object',
        properties = {
          buffer_id = { type = 'integer', description = 'Buffer ID (defaults to the source buffer)' },
          start_line = { type = 'integer', description = 'First line (default 1)' },
          end_line = { type = 'integer', description = 'Last line (default: up to 200 lines)' },
        },
      },
    },
  },
  {
    type = 'function',
    ['function'] = {
      name = 'replace_buffer_lines',
      description = 'Replace at most 200 lines in a loaded ordinary buffer after confirmation. Saves named files unless already modified. Lines are 1-based/inclusive; read first and expected_text must match exactly. Replacement at most 200KB; empty new_text deletes lines.',
      parameters = {
        type = 'object',
        properties = {
          buffer_id = { type = 'integer', description = 'Buffer ID (defaults to the source buffer)' },
          start_line = { type = 'integer' },
          end_line = { type = 'integer' },
          expected_text = { type = 'string', description = 'Exact text of existing lines, joined with newlines' },
          new_text = { type = 'string', description = 'Replacement text; empty string deletes lines' },
        },
        required = { 'start_line', 'end_line', 'expected_text', 'new_text' },
      },
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

local function valid_buffer(id)
  return type(id) == 'number' and id >= 0 and id < math.huge and id % 1 == 0
    and vim.api.nvim_buf_is_valid(id) and vim.api.nvim_buf_is_loaded(id)
end

local function target(args, source)
  local id = args.buffer_id or source
  if not valid_buffer(id) then return nil, 'Buffer is not loaded or does not exist' end
  if vim.bo[id].buftype ~= '' then return nil, 'Only ordinary file buffers can be accessed' end
  return id
end

local function range(args, id)
  local start = args.start_line or 1
  if type(start) ~= 'number' or start < 1 or start == math.huge or start % 1 ~= 0 then
    return nil, nil, 'Invalid line range'
  end
  local last = args.end_line or math.min(start + 199, vim.api.nvim_buf_line_count(id))
  if type(start) ~= 'number' or type(last) ~= 'number' or start % 1 ~= 0 or last % 1 ~= 0
    or start < 1 or last < start or last > vim.api.nvim_buf_line_count(id) then
    return nil, nil, 'Invalid line range'
  end
  if last - start >= 200 then return nil, nil, 'Read/edit at most 200 lines per call' end
  return start, last
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
      return
    end
  end
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
    local buffers = {}
    for _, id in ipairs(vim.api.nvim_list_bufs()) do
      if valid_buffer(id) and vim.bo[id].buftype == '' and vim.api.nvim_buf_get_name(id) ~= '' then
        table.insert(buffers, { id = id, name = vim.api.nvim_buf_get_name(id), modified = vim.bo[id].modified })
      end
    end
    return done(vim.json.encode(buffers))
  end
  if name == 'load_skill' then
    local workspace = require('codeit.history').workspace()
    local skill = require('codeit.context_files').skill(args.name, workspace,
      approval.workspace_trust(workspace))
    return done(skill and ('Skill ' .. args.name .. ' (' .. skill.path .. '):\n' .. skill.content)
      or 'Error: skill is not available or workspace is not trusted')
  end
  if name ~= 'read_buffer' and name ~= 'replace_buffer_lines' then
    return agent_tools.execute(name, args, done, active, gate, reads, prepare)
  end
  local id, err = target(args, source)
  if not id then return done('Error: ' .. err) end
  file_buffer.refresh(id)
  if name == 'read_buffer' then
    local start, last = args.start_line or 1, args.end_line
    if start < 1 or last ~= nil and last < start then return done('Error: Invalid line range') end
    local result, read_err = file_buffer.read(id, start, last)
    if not result then return done('Error: ' .. read_err) end
    result.buffer_id = id
    file_buffer.remember(id, reads)
    return done(vim.json.encode(result))
  end
  if not prepare(vim.api.nvim_buf_get_name(id)) then
    return done('Error: new project instructions discovered; review them before reissuing this edit')
  end
  if not file_buffer.was_read(id, reads) then return done('Error: read the current buffer before editing') end
  local start, last, range_err = range(args, id)
  if range_err then return done('Error: ' .. range_err) end
  local lines = vim.api.nvim_buf_get_lines(id, start - 1, last, false)
  if #args.expected_text > 200000 or #args.new_text > 200000 then
    return done('Error: replacement text must be at most 200KB')
  end
  if not vim.bo[id].modifiable then return done('Error: buffer is not modifiable') end
  if table.concat(lines, '\n') ~= args.expected_text then
    return done('Error: buffer contents changed; read the buffer again before editing')
  end
  local changedtick = vim.api.nvim_buf_get_changedtick(id)
  local was_modified = vim.bo[id].modified
  local disk_version = file_buffer.disk_version(id)
  local replacement = args.new_text == '' and {} or vim.split(args.new_text, '\n', { plain = true })
  local before = vim.api.nvim_buf_get_lines(id, 0, -1, false)
  local after = vim.deepcopy(before)
  for _ = start, last do table.remove(after, start) end
  for i, line in ipairs(replacement) do table.insert(after, start + i - 1, line) end
  local eol = vim.bo[id].endofline and '\n' or ''
  local preview = { path = vim.api.nvim_buf_get_name(id), filetype = vim.bo[id].filetype,
    before = table.concat(before, '\n') .. eol, after = table.concat(after, '\n') .. eol }
  return gate(string.format('Replace lines %d-%d in %s?', start, last, preview.path), function()
    if active and not active() then return end
    if not valid_buffer(id) or vim.api.nvim_buf_get_changedtick(id) ~= changedtick
      or vim.bo[id].modified ~= was_modified or file_buffer.disk_version(id) ~= disk_version then
      return done('Error: buffer changed while awaiting confirmation')
    end
    if not vim.bo[id].modifiable then return done('Error: buffer is not modifiable') end
    local ok, edit_err = pcall(vim.api.nvim_buf_set_lines, id, start - 1, last, false, replacement)
    if not ok then return done('Error: ' .. tostring(edit_err)) end
    local result = require('codeit.write_buffer').finish(id, was_modified)
    file_buffer.remember(id, reads)
    done(result)
  end, preview)
end

return M
