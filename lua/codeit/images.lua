local M = {}

M.max_size = 10 * 1024 * 1024

local signatures = {
  { mime = 'image/png', bytes = '\137PNG\r\n\026\n' },
  { mime = 'image/jpeg', bytes = '\255\216\255' },
  { mime = 'image/gif', bytes = 'GIF87a' },
  { mime = 'image/gif', bytes = 'GIF89a' },
  { mime = 'image/webp', bytes = 'RIFF', check = function(data) return data:sub(9, 12) == 'WEBP' end },
}

local function mime(data)
  for _, signature in ipairs(signatures) do
    if data:sub(1, #signature.bytes) == signature.bytes
      and (not signature.check or signature.check(data)) then
      return signature.mime
    end
  end
end

function M.load(path)
  local resolved, err = require('codeit.tools.workspace.paths').resolve(path, true, true)
  if not resolved then return nil, err end
  local canonical = vim.uv.fs_realpath(resolved) or resolved
  for _, id in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(id) and vim.bo[id].buftype == '' and vim.bo[id].modified
      and vim.uv.fs_realpath(vim.api.nvim_buf_get_name(id)) == canonical then
      return nil, 'Image has unsaved buffer changes; save it before reading'
    end
  end
  local stat = vim.uv.fs_stat(canonical)
  if not stat or stat.type ~= 'file' then return nil, 'Not a regular file' end
  if stat.size > M.max_size then return nil, 'Image exceeds the 10 MiB limit' end
  local file = io.open(canonical, 'rb')
  if not file then return nil, 'Cannot read image' end
  local data = file:read(M.max_size + 1)
  file:close()
  if data and #data > M.max_size then return nil, 'Image exceeds the 10 MiB limit' end
  if not data or #data ~= stat.size then return nil, 'Cannot read image completely' end
  local content_type = mime(data)
  if not content_type then return nil, 'Unsupported image format (expected PNG, JPEG, GIF, or WebP)' end
  local encoded = vim.base64.encode(data)
  return { type = 'image_url', image_url = { url = 'data:' .. content_type .. ';base64,' .. vim.trim(encoded), detail = 'auto' } }, canonical
end

-- Summaries and text-only reviewers need image labels, not encoded pixel data.
function M.reference(value)
  if type(value) ~= 'table' then return value end
  if value.type == 'image_url' then return { type = 'text', text = '[Image content omitted from text-only reference]' } end
  local copy = {}
  for key, child in pairs(value) do copy[key] = M.reference(child) end
  return copy
end

return M
