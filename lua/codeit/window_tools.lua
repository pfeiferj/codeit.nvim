local M = {}
local layout = require('codeit.managed_tab')
local buffers = require('codeit.file_buffer')

local function spec(name, description, properties, required)
  return { type = 'function', ['function'] = { name = name, description = description,
    parameters = { type = 'object', properties = properties or vim.empty_dict(),
      required = required or {}, additionalProperties = false } } }
end
local window = { type = 'integer', minimum = 1, description = 'File window ID from list_windows; must belong to the Codeit tab' }
local target = {
  window_id = window,
  path = { type = 'string', minLength = 1, description = 'Existing workspace file; if buffer_id is also given, both must identify the same file' },
  buffer_id = { type = 'integer', minimum = 1, description = 'Already-loaded ordinary buffer, including unnamed/external buffers; if path is also given, both must identify the same file' },
}
M.specs = {
  spec('list_windows', 'List ordinary file windows in the managed Codeit tab (IDs, paths, sizes, modified and user_attached flags). Excludes chat and popups. No buffer text is returned.'),
  spec('open_window_buffer', 'Display a workspace file or loaded ordinary buffer in an existing Codeit file window. Does not read text, save, or discard edits. Assistant attachments do not grant read permission; workspace trust still applies.', target, { 'window_id' }),
  spec('split_window', 'Split a Codeit file window horizontally or vertically, optionally displaying a path or buffer_id in the new window. Returns its IDs and size. Even inherited buffers are assistant-attached; splitting does not grant read permission.', vim.tbl_extend('force', target, {
    direction = { type = 'string', description = 'horizontal (default) or vertical' },
  }), { 'window_id' }),
  spec('resize_window', 'Resize a Codeit file window. Neovim may constrain the requested dimensions or resize adjacent splits. Returns actual dimensions.', {
    window_id = window, width = { type = 'integer', minimum = 1 }, height = { type = 'integer', minimum = 1 },
  }, { 'window_id' }),
  spec('focus_window', 'Focus a file window in the Codeit tab so the user can interact with it. Cannot focus windows in other tabs or popups.', { window_id = window }, { 'window_id' }),
  spec('close_window', 'Close a Codeit file split without saving or deleting its buffer. Refuses the last file view and buffers with destructive bufhidden settings.', { window_id = window }, { 'window_id' }),
  spec('read_window_buffer', 'Read the ordinary buffer currently visible in a Codeit file window, including unsaved changes. User-attached visible buffers need no approval; assistant-attached buffers follow workspace trust. Same 1-based/inclusive 200-line/20000-byte limits and continuation fields as read_loaded_buffer.', {
    window_id = window, start_line = { type = 'integer', minimum = 1 }, end_line = { type = 'integer', minimum = 1 },
  }, { 'window_id' }),
}
M.names = {}
for _, entry in ipairs(M.specs) do M.names[entry['function'].name] = true end

local function target_buffer(args)
  if args.buffer_id and not args.path then return buffers.target(args) end
  if not args.path then return nil, 'Specify path or buffer_id' end
  if args.path:find('\0', 1, true) then return nil, 'Invalid path' end
  local root = vim.uv.fs_realpath(vim.fn.getcwd())
  local path = root and vim.fs.normalize(args.path:sub(1, 1) == '/' and args.path or root .. '/' .. args.path)
  local real = path and vim.uv.fs_realpath(path)
  local stat = real and vim.uv.fs_stat(real)
  if not root or not real or real:sub(1, #root + 1) ~= root .. '/' or not stat or stat.type ~= 'file' then
    return nil, 'Path must resolve to an existing regular workspace file'
  end
  if args.buffer_id then
    local id, err = buffers.target(args)
    if not id then return nil, err end
    if vim.uv.fs_realpath(vim.api.nvim_buf_get_name(id)) ~= real then
      return nil, 'path and buffer_id must identify the same file'
    end
    return id
  end
  local id = vim.fn.bufadd(path)
  -- Loading may run user autocmds; none of their attachments grant user-read trust.
  layout.assistant(function() vim.fn.bufload(id) end)
  return buffers.target({ buffer_id = id })
end

function M.execute(name, args, done, reads)
  if name == 'list_windows' then
    local result = {}
    for _, win in ipairs(layout.windows()) do result[#result + 1] = layout.describe(win) end
    return done(vim.json.encode({ tab_id = layout.tab(), windows = result }))
  end
  local win = args.window_id
  local id = layout.buffer(win)
  if not id then return done('Error: window is not an ordinary file view in the Codeit tab') end
  if name == 'read_window_buffer' then
    local start = args.start_line or 1
    if args.end_line and args.end_line < start then return done('Error: invalid line range') end
    buffers.refresh(id)
    local result, err = buffers.read(id, start, args.end_line)
    if not result then return done('Error: ' .. err) end
    result.path, result.buffer_id, result.window_id = vim.api.nvim_buf_get_name(id), id, win
    buffers.remember(id, reads)
    return done(vim.json.encode(result))
  end
  if name == 'open_window_buffer' or name == 'split_window' then
    if args.direction and args.direction ~= 'horizontal' and args.direction ~= 'vertical' then
      return done('Error: direction must be horizontal or vertical')
    end
    local target, err
    if name == 'open_window_buffer' and vim.bo[id].bufhidden ~= '' and vim.bo[id].bufhidden ~= 'hide' then
      return done('Error: replacing this view could unload or delete its buffer (bufhidden)')
    end
    if name == 'open_window_buffer' or args.path or args.buffer_id then
      target, err = target_buffer(args)
      if not target then return done('Error: ' .. err) end
    end
    if layout.buffer(win) ~= id then return done('Error: window changed while loading the target') end
    if name == 'split_window' then win = layout.split(win, args.direction) end
    if target then layout.attach(win, target) end
  elseif name == 'resize_window' then
    if not args.width and not args.height then return done('Error: specify width or height') end
    if args.width then vim.api.nvim_win_set_width(win, args.width) end
    if args.height then vim.api.nvim_win_set_height(win, args.height) end
  elseif name == 'focus_window' then
    layout.open()
    vim.api.nvim_set_current_win(win)
  elseif name == 'close_window' then
    if #layout.windows() <= 1 then return done('Error: cannot close the last Codeit file view') end
    if vim.bo[id].bufhidden ~= '' and vim.bo[id].bufhidden ~= 'hide' then
      return done('Error: bufhidden would unload or delete the buffer')
    end
    vim.api.nvim_win_hide(win)
    return done(vim.json.encode({ closed_window_id = win, buffer_id = id }))
  end
  return done(vim.json.encode(layout.describe(win)))
end

return M
