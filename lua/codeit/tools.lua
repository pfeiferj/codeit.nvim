local M = {}
local agent_tools = require('codeit.agent_tools')
local approval = require('codeit.approval')

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
      description = 'Read lines from a loaded Neovim buffer. Omit buffer_id to read the buffer active before the chat opened. Lines are 1-based and inclusive.',
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
      description = 'Replace a range of lines in a loaded buffer after user confirmation. Lines are 1-based and inclusive; expected_text must match the existing lines exactly.',
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

local function valid_buffer(id)
  return type(id) == 'number' and vim.api.nvim_buf_is_valid(id) and vim.api.nvim_buf_is_loaded(id)
end

local function target(args, source)
  local id = args.buffer_id or source
  if not valid_buffer(id) then return nil, 'Buffer is not loaded or does not exist' end
  if vim.bo[id].buftype ~= '' then return nil, 'Only ordinary file buffers can be accessed' end
  return id
end

local function range(args, id)
  local start = args.start_line or 1
  local last = args.end_line or math.min(start + 199, vim.api.nvim_buf_line_count(id))
  if type(start) ~= 'number' or type(last) ~= 'number' or start % 1 ~= 0 or last % 1 ~= 0
    or start < 1 or last < start or last > vim.api.nvim_buf_line_count(id) then
    return nil, nil, 'Invalid line range'
  end
  if last - start >= 200 then return nil, nil, 'Read/edit at most 200 lines per call' end
  return start, last
end

local execute_approved

--- Execute a tool and call done(result_string, optional_cancel_signal).
function M.execute(name, args, source, done, active, context)
  if type(args) ~= 'table' or vim.islist(args) and #args > 0 then return done('Error: arguments must be an object') end
  local function gate(prompt, action, diff)
    local request_context = vim.tbl_extend('force', context or {}, { source_buffer = source })
    request_context.diff = diff
    return approval.request(name, args, prompt, active, done, action, request_context)
  end
  if not gated[name] then
    return gate('Allow ' .. tostring(name) .. ' ' .. vim.json.encode(args) .. '?', function()
      execute_approved(name, args, source, done, active, gate)
    end)
  end
  return execute_approved(name, args, source, done, active, gate)
end

execute_approved = function(name, args, source, done, active, gate)
  if name == 'list_buffers' then
    local buffers = {}
    for _, id in ipairs(vim.api.nvim_list_bufs()) do
      if valid_buffer(id) and vim.bo[id].buftype == '' and vim.api.nvim_buf_get_name(id) ~= '' then
        table.insert(buffers, { id = id, name = vim.api.nvim_buf_get_name(id), modified = vim.bo[id].modified })
      end
    end
    return done(vim.json.encode(buffers))
  end
  if name ~= 'read_buffer' and name ~= 'replace_buffer_lines' then
    return agent_tools.execute(name, args, done, active, gate)
  end
  local id, err = target(args, source)
  if not id then return done('Error: ' .. err) end
  local start, last, range_err = range(args, id)
  if range_err then return done('Error: ' .. range_err) end
  local lines = vim.api.nvim_buf_get_lines(id, start - 1, last, false)
  if name == 'read_buffer' then
    return done(vim.json.encode({ buffer_id = id, start_line = start, end_line = last, lines = lines }))
  end
  if type(args.expected_text) ~= 'string' or type(args.new_text) ~= 'string' then
    return done('Error: expected_text and new_text must be strings')
  end
  if not vim.bo[id].modifiable then return done('Error: buffer is not modifiable') end
  if table.concat(lines, '\n') ~= args.expected_text then
    return done('Error: buffer contents changed; read the buffer again before editing')
  end
  local changedtick = vim.api.nvim_buf_get_changedtick(id)
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
    if not valid_buffer(id) or vim.api.nvim_buf_get_changedtick(id) ~= changedtick then
      return done('Error: buffer changed while awaiting confirmation')
    end
    if not vim.bo[id].modifiable then return done('Error: buffer is not modifiable') end
    local ok, edit_err = pcall(vim.api.nvim_buf_set_lines, id, start - 1, last, false, replacement)
    done(ok and 'Applied edit' or ('Error: ' .. tostring(edit_err)))
  end, preview)
end

return M
