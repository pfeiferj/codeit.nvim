local M = {}
local layout = require('codeit.managed_tab')
local buffers = require('codeit.file_buffer')

local function spec(name, description, properties, required)
  return { type = 'function', ['function'] = { name = name, description = description,
    parameters = { type = 'object', properties = properties or vim.empty_dict(),
      required = required or {}, additionalProperties = false } } }
end
local window = { type = 'integer', minimum = 1, description = 'File window ID from list_windows; must belong to the Codeit tab' }
local path = { type = 'string', minLength = 1, description = 'Existing regular file inside the workspace' }
local buffer = { type = 'integer', minimum = 1, description = 'Already-loaded ordinary buffer ID, including unnamed or external buffers' }
local direction = { type = 'string', description = 'horizontal (default) or vertical' }
M.specs = {
  spec('list_windows', 'List ordinary file windows in the managed Codeit tab (IDs, paths, sizes, cursor_line, cursor_column, top_line, modified and user_attached flags). Positions are 1-based; columns are byte offsets. Excludes chat and popups. No buffer text is returned.'),
  spec('open_window_file', 'Display an existing workspace file by path in a Codeit file window. Does not read text, save, or discard edits. Assistant attachments do not grant read permission; workspace trust still applies.', { window_id = window, path = path }, { 'window_id', 'path' }),
  spec('open_window_buffer', 'Display an already-loaded ordinary buffer by ID in a Codeit file window. Does not read text, save, or discard edits. Assistant attachments do not grant read permission; workspace trust still applies.', { window_id = window, buffer_id = buffer }, { 'window_id', 'buffer_id' }),
  spec('split_window', 'Split a Codeit file window horizontally or vertically, inheriting its current buffer. Returns its IDs and size. Inherited buffers are assistant-attached; splitting does not grant read permission.', { window_id = window, direction = direction }, { 'window_id' }),
  spec('split_window_file', 'Split a Codeit file window horizontally or vertically and display an existing workspace file by path in the new window. Returns its IDs and size. Does not read text or save files; assistant attachments do not grant read permission.', { window_id = window, direction = direction, path = path }, { 'window_id', 'path' }),
  spec('split_window_buffer', 'Split a Codeit file window horizontally or vertically and display an already-loaded ordinary buffer by ID in the new window. Returns its IDs and size. Does not read text or save files; assistant attachments do not grant read permission.', { window_id = window, direction = direction, buffer_id = buffer }, { 'window_id', 'buffer_id' }),
  spec('resize_window', 'Resize a Codeit file window. Neovim may constrain the requested dimensions or resize adjacent splits. Returns actual dimensions.', {
    window_id = window, width = { type = 'integer', minimum = 1 }, height = { type = 'integer', minimum = 1 },
  }, { 'window_id' }),
  spec('set_window_cursor', 'Place the cursor in a Codeit file window without changing focus. Line and byte column are 1-based; column defaults to 1 and is clamped to the line. Opens folds at the target and places it about 25% from the top by default. Returns actual cursor_line, cursor_column and top_line. Does not read text, save files, or grant read permission.', {
    window_id = window, line = { type = 'integer', minimum = 1 },
    column = { type = 'integer', minimum = 1 }, center = { type = 'boolean', description = 'Reposition the target about 25% from the top (default true); false preserves normal cursor scrolling' },
  }, { 'window_id', 'line' }),
  spec('scroll_window', 'Scroll a Codeit file window by screen lines without changing focus. Positive lines scroll down, negative lines scroll up; zero does nothing. Neovim clamps at buffer boundaries and may move the cursor to keep it visible. Returns actual cursor_line, cursor_column and top_line. Does not read text, save files, or grant read permission.', {
    window_id = window, lines = { type = 'integer', minimum = -2147483647, maximum = 2147483647 },
  }, { 'window_id', 'lines' }),
  spec('focus_window', 'Focus a file window in the Codeit tab so the user can interact with it. Cannot focus windows in other tabs or popups.', { window_id = window }, { 'window_id' }),
  spec('close_window', 'Close a Codeit file split without saving or deleting its buffer. Refuses the last file view and buffers with destructive bufhidden settings.', { window_id = window }, { 'window_id' }),
  spec('read_window_buffer', 'Read the ordinary buffer currently visible in a Codeit file window, including unsaved changes. User-attached visible buffers need no approval; assistant-attached buffers follow workspace trust. Same 1-based/inclusive 200-line/20000-byte limits and continuation fields as read_loaded_buffer.', {
    window_id = window, start_line = { type = 'integer', minimum = 1 }, end_line = { type = 'integer', minimum = 1 },
  }, { 'window_id' }),
}
M.names = {}
for _, entry in ipairs(M.specs) do M.names[entry['function'].name] = true end

local function target_file(args)
  if args.path:find('\0', 1, true) then return nil, 'Invalid path' end
  local root = vim.uv.fs_realpath(vim.fn.getcwd())
  local path = root and vim.fs.normalize(args.path:sub(1, 1) == '/' and args.path or root .. '/' .. args.path)
  local real = path and vim.uv.fs_realpath(path)
  local stat = real and vim.uv.fs_stat(real)
  if not root or not real or real:sub(1, #root + 1) ~= root .. '/' or not stat or stat.type ~= 'file' then
    return nil, 'Path must resolve to an existing regular workspace file'
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
  local opening = name == 'open_window_file' or name == 'open_window_buffer'
  local splitting = name == 'split_window' or name == 'split_window_file' or name == 'split_window_buffer'
  if opening or splitting then
    if args.direction and args.direction ~= 'horizontal' and args.direction ~= 'vertical' then
      return done('Error: direction must be horizontal or vertical')
    end
    local target, err
    if opening and vim.bo[id].bufhidden ~= '' and vim.bo[id].bufhidden ~= 'hide' then
      return done('Error: replacing this view could unload or delete its buffer (bufhidden)')
    end
    if name == 'open_window_file' or name == 'split_window_file' then
      target, err = target_file(args)
    elseif name == 'open_window_buffer' or name == 'split_window_buffer' then
      target, err = buffers.target(args)
    end
    if name ~= 'split_window' and not target then return done('Error: ' .. err) end
    if layout.buffer(win) ~= id then return done('Error: window changed while loading the target') end
    if splitting then win = layout.split(win, args.direction) end
    if target then layout.attach(win, target) end
  elseif name == 'resize_window' then
    if not args.width and not args.height then return done('Error: specify width or height') end
    if args.width then vim.api.nvim_win_set_width(win, args.width) end
    if args.height then vim.api.nvim_win_set_height(win, args.height) end
  elseif name == 'set_window_cursor' then
    if args.line > vim.api.nvim_buf_line_count(id) then return done('Error: line is past the end of the buffer') end
    layout.assistant(function()
      vim.api.nvim_win_set_cursor(win, { args.line, (args.column or 1) - 1 })
      vim.api.nvim_win_call(win, function()
        vim.cmd('normal! zv')
        if args.center ~= false then
          local above = math.max(0, math.floor(vim.api.nvim_win_get_height(win) / 4) - 1)
          vim.cmd('normal! zt')
          if above > 0 then
            vim.cmd('normal! ' .. above .. vim.api.nvim_replace_termcodes('<C-y>', true, false, true))
          end
        end
      end)
    end)
  elseif name == 'scroll_window' then
    if args.lines ~= 0 then
      layout.assistant(function()
        vim.api.nvim_win_call(win, function()
          local key = args.lines > 0 and '<C-e>' or '<C-y>'
          vim.cmd('normal! ' .. math.abs(args.lines) .. vim.api.nvim_replace_termcodes(key, true, false, true))
        end)
      end)
    end
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
