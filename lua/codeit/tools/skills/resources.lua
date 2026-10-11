local M = {}
local buffers = require('codeit.file_buffer')

local function within(path, root)
  return path == root or path:sub(1, #root + 1) == root .. '/'
end

function M.resolve(args, workspace, mode, selected)
  if type(args.path) ~= 'string' or args.path == '' or args.path:find('\0', 1, true)
    or args.path:match('^[\\/]') or args.path:match('^%a:') then
    return nil, 'resource path must be relative to the active skill directory'
  end
  for part in args.path:gmatch('[^/\\]+') do
    if part == '..' then return nil, 'resource path must not contain parent traversal' end
  end
  for _, entry in ipairs(require('codeit.context_files').entries(workspace, mode, {}, selected)) do
    if entry.kind == 'skill' and entry.name == args.skill and entry.included then
      local root = vim.uv.fs_realpath(vim.fn.fnamemodify(entry.path, ':h'))
      local path = root and vim.uv.fs_realpath(root .. '/' .. args.path)
      local stat = path and vim.uv.fs_stat(path)
      if not root or not path or not within(path, root) or not stat or stat.type ~= 'file' then
        return nil, 'resource must be an existing regular file inside the active skill directory'
      end
      if path == vim.uv.fs_realpath(entry.path) then return nil, 'main skill instructions are already in context; read a supporting resource instead' end
      if stat.size > 1000000 then return nil, 'resource exceeds 1 MB' end
      return { path = path, skill_path = entry.path }
    end
  end
  return nil, 'skill is not active, is disabled, or workspace is not trusted'
end

function M.read(resource, args, reads)
  local file, err = io.open(resource.path, 'rb')
  if not file then return nil, err end
  local text = file:read(1000001)
  file:close()
  if not text or #text > 1000000 or text:find('\0', 1, true) then return nil, 'resource must be a text file of at most 1 MB' end
  local id = vim.fn.bufadd(resource.path)
  vim.fn.bufload(id)
  if vim.bo[id].buftype ~= '' then return nil, 'resource is not an ordinary file buffer' end
  buffers.refresh(id)
  local result, read_err = buffers.read(id, args.start_line or 1, args.end_line)
  if not result then return nil, read_err end
  result.path, result.buffer_id, result.skill = resource.path, id, args.skill
  result.reference_data = true
  buffers.remember(id, reads)
  return result
end

return M
