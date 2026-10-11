local M = {}
local markdown = require('codeit.markdown')

local function pretty_json(value, depth)
  if type(value) ~= 'table' then return vim.json.encode(value) end
  local indent = string.rep('  ', depth)
  local child_indent = indent .. '  '
  local parts = {}
  if vim.islist(value) then
    for _, item in ipairs(value) do parts[#parts + 1] = child_indent .. pretty_json(item, depth + 1) end
    if #parts == 0 then return '[]' end
    return '[\n' .. table.concat(parts, ',\n') .. '\n' .. indent .. ']'
  end
  local keys = vim.tbl_keys(value)
  table.sort(keys)
  for _, key in ipairs(keys) do
    parts[#parts + 1] = child_indent .. vim.json.encode(key) .. ': ' .. pretty_json(value[key], depth + 1)
  end
  if #parts == 0 then return '{}' end
  return '{\n' .. table.concat(parts, ',\n') .. '\n' .. indent .. '}'
end

M.pretty_json = function(value) return pretty_json(value, 0) end

local function shell_arg(arg)
  if arg:match('^[%w_@%%+=:,./-]+$') then return arg end
  return "'" .. arg:gsub("'", "'\\''") .. "'"
end

local function command(argv)
  local parts = {}
  for _, arg in ipairs(argv) do parts[#parts + 1] = shell_arg(arg) end
  local single_line = table.concat(parts, ' ')
  if #single_line <= 80 then return single_line end
  return table.concat(parts, ' \\\n  ')
end

--- Render the exact arguments being approved, with a readable shell representation
--- for argv-based calls (which are executed directly, not through a shell).
function M.call(name, args)
  local language, input = 'json', pretty_json(args, 0)
  local extras
  if (name == 'run_command' or name == 'start_background_task') and type(args.argv) == 'table' and #args.argv > 0 then
    local valid = true
    for _, arg in ipairs(args.argv) do
      if type(arg) ~= 'string' then valid = false; break end
    end
    if valid then
      language, input = 'bash', command(args.argv)
      extras = {}
      for key, value in pairs(args) do
        if key ~= 'argv' then extras[key] = value end
      end
    end
  end
  local lines = { '# ' .. tostring(name):gsub('([\\`*{}%[%]()<>#!|])', '\\%1'), '' }
  vim.list_extend(lines, markdown.fence(input, language))
  if extras and next(extras) then
    vim.list_extend(lines, { '', 'Other arguments:', '' })
    vim.list_extend(lines, markdown.fence(pretty_json(extras, 0), 'json'))
  end
  return table.concat(lines, '\n')
end

return M
