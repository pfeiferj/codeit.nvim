local M = {}

M.max_size = 10 * 1024 * 1024

local function detect(data)
  if data:sub(1, 8) == '\137PNG\r\n\026\n' then return 'image', 'image/png' end
  if data:sub(1, 3) == '\255\216\255' then return 'image', 'image/jpeg' end
  if data:sub(1, 6) == 'GIF87a' or data:sub(1, 6) == 'GIF89a' then return 'image', 'image/gif' end
  if data:sub(1, 4) == 'RIFF' and data:sub(9, 12) == 'WEBP' then return 'image', 'image/webp' end
  if data:sub(1, 5) == '%PDF-' then return 'pdf', 'application/pdf' end
  if data:sub(1, 4) == 'RIFF' and data:sub(9, 12) == 'WAVE' then return 'audio', 'wav' end
  if data:sub(1, 3) == 'ID3' then return 'audio', 'mp3' end
  -- MPEG Layer III has a sync word like AAC, but different version/layer bits.
  local second = data:byte(2) or 0
  if #data >= 4 and data:byte(1) == 0xff and second >= 0xe0
    and math.floor(second / 8) % 4 ~= 1 and math.floor(second / 2) % 4 == 1 then
    return 'audio', 'mp3'
  end
end

function M.is_part(value)
  return type(value) == 'table' and (value.type == 'image_url' or value.type == 'file' or value.type == 'input_audio')
end

function M.load(path, expected)
  if expected ~= nil and not vim.tbl_contains({ 'image', 'pdf', 'audio' }, expected) then
    return nil, 'Invalid attachment type (expected image, pdf, or audio)'
  end
  local resolved, err = require('codeit.tools.workspace.paths').resolve(path, true, true)
  if not resolved then return nil, err end
  local canonical = vim.uv.fs_realpath(resolved) or resolved
  for _, id in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(id) and vim.bo[id].buftype == '' and vim.bo[id].modified
      and vim.uv.fs_realpath(vim.api.nvim_buf_get_name(id)) == canonical then
      return nil, 'Attachment has unsaved buffer changes; save it before reading'
    end
  end
  local stat = vim.uv.fs_stat(canonical)
  if not stat or stat.type ~= 'file' then return nil, 'Not a regular file' end
  if stat.size > M.max_size then return nil, 'Attachment exceeds the 10 MiB limit' end
  local file = io.open(canonical, 'rb')
  if not file then return nil, 'Cannot read attachment' end
  local data = file:read(M.max_size + 1)
  file:close()
  if data and #data > M.max_size then return nil, 'Attachment exceeds the 10 MiB limit' end
  if not data or #data ~= stat.size then return nil, 'Cannot read attachment completely' end
  local kind, format = detect(data)
  if not kind then return nil, 'Unsupported attachment format (expected image, PDF, WAV, or MP3)' end
  if expected and expected ~= kind then return nil, 'Attachment is ' .. kind .. ', not ' .. expected end
  local encoded = vim.trim(vim.base64.encode(data))
  local part
  if kind == 'image' then
    part = { type = 'image_url', image_url = { url = 'data:' .. format .. ';base64,' .. encoded, detail = 'auto' } }
  elseif kind == 'pdf' then
    part = { type = 'file', file = { filename = vim.fn.fnamemodify(canonical, ':t'), file_data = 'data:application/pdf;base64,' .. encoded } }
  else
    part = { type = 'input_audio', input_audio = { data = encoded, format = format } }
  end
  return part, canonical, kind
end

function M.reference(value)
  if type(value) ~= 'table' then return value end
  if M.is_part(value) then return { type = 'text', text = '[Attachment content omitted from text-only reference]' } end
  local copy = {}
  for key, child in pairs(value) do copy[key] = M.reference(child) end
  return copy
end

return M
