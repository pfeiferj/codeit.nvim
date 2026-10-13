local M = {}
local spec = require('codeit.tools.spec')
local paths = require('codeit.tools.workspace.paths')
local buffers = require('codeit.file_buffer')
local edits = require('codeit.tools.workspace.edits')
local resolve, integer = paths.resolve, paths.integer

local replacement_properties = {
  old_text = { type = 'string', minLength = 1, maxLength = 200000 },
  new_text = { type = 'string', maxLength = 200000 },
  start_line = { type = 'integer', minimum = 1, description = 'Optional paired range in the ORIGINAL revision. Omit both bounds when old_text is globally unique; do not count lines after earlier edits.' },
  end_line = { type = 'integer', minimum = 1, description = 'Inclusive end of the optional original-revision range; requires start_line. Matches outside this range are never used.' },
}

local function edit_properties(target)
  local properties = {
    edits = { type = 'array', minItems = 1, maxItems = 50, items = {
      type = 'object', properties = replacement_properties, required = { 'old_text', 'new_text' }, additionalProperties = false,
    } },
  }
  if target == 'path' then properties.path = { type = 'string', minLength = 1 }
  elseif target == 'buffer_id' then properties.buffer_id = { type = 'integer', minimum = 1 } end
  return properties
end

M.specs = {
  spec('read_file', 'Read a file by path in the current workspace or another trusted directory, including unsaved changes if loaded. Clean buffers refresh from disk. Lines are 1-based/inclusive. At most 200 lines/20000 encoded bytes, even with end_line. Returns path, buffer_id, lines (exact text), parallel line_numbers (original 1-based numbers), total_lines, truncated, next_start_line, modified; continue at next_start_line. Ranges past EOF return available lines. For a loaded buffer ID or the source buffer, use read_loaded_buffer or read_source_buffer instead.', {
    path = { type = 'string', minLength = 1, description = 'File path (required); paths outside the current workspace must resolve inside a trusted directory. Do not pass a buffer ID.' },
    start_line = { type = 'integer', minimum = 1 }, end_line = { type = 'integer', minimum = 1 },
  }, { 'path' }),
  spec('read_loaded_buffer', 'Read a loaded ordinary buffer by ID, including unnamed buffers and unsaved changes. Use read_file instead for a workspace path. Lines are 1-based/inclusive; at most 200 lines/20000 encoded bytes. Returns path, buffer_id, lines (exact text), parallel line_numbers (original 1-based numbers), total_lines, truncated, next_start_line, modified.', {
    buffer_id = { type = 'integer', minimum = 1, description = 'Loaded ordinary buffer ID (required). Do not pass a path.' },
    start_line = { type = 'integer', minimum = 1 }, end_line = { type = 'integer', minimum = 1 },
  }, { 'buffer_id' }),
  spec('read_source_buffer', 'Read the ordinary buffer active before the chat opened. No path or buffer ID needed. Includes unsaved changes. Lines are 1-based/inclusive; at most 200 lines/20000 encoded bytes. Returns path, buffer_id, lines (exact text), parallel line_numbers (original 1-based numbers), total_lines, truncated, next_start_line, modified.', {
    start_line = { type = 'integer', minimum = 1 }, end_line = { type = 'integer', minimum = 1 },
  }),
  spec('edit_file', 'Edit a workspace file by path. Read first. Pass required edits array (1-50 objects with old_text and new_text, even for one replacement); put optional start_line/end_line inside each edit. Exact old_text matches the ORIGINAL revision once; optional paired start_line/end_line scope each match. Overlaps reject the entire batch. Preview and approve once; save clean named files, preserve unsaved changes. Use edit_loaded_buffer or edit_source_buffer for buffer targets.', edit_properties('path'), { 'path', 'edits' }),
  spec('edit_loaded_buffer', 'Edit a loaded ordinary buffer by ID, including unnamed or unsaved buffers. Read first. Pass required edits array (1-50 objects with old_text and new_text, even for one replacement); put optional start_line/end_line inside each edit. Exact old_text matches the ORIGINAL revision once; optional paired start_line/end_line scope each match. Overlaps reject the entire batch. Preview and approve once; save clean named files, preserve unsaved changes.', edit_properties('buffer_id'), { 'buffer_id', 'edits' }),
  spec('edit_source_buffer', 'Edit the ordinary buffer active before chat opened. No path or buffer ID needed. Read first. Pass required edits array (1-50 objects with old_text and new_text, even for one replacement); put optional start_line/end_line inside each edit. Exact old_text matches the ORIGINAL revision once; optional paired start_line/end_line scope each match. Overlaps reject the entire batch. Preview and approve once; save clean named files, preserve unsaved changes.', edit_properties(), { 'edits' }),
  spec('save_buffer', 'Save ALL changes in a named loaded ordinary buffer by workspace path, including the user\'s changes. Requires explicit approval with a disk-to-buffer preview. The buffer must already be loaded; no implicit save before tests.', {
    path = { type = 'string', minLength = 1 },
  }, { 'path' }),
  spec('save_loaded_buffer', 'Save ALL changes in a named loaded ordinary buffer by ID, including the user\'s changes. Requires explicit approval with a disk-to-buffer preview. Does not name unnamed buffers or force overwrite externally changed files.', {
    buffer_id = { type = 'integer', minimum = 1 },
  }, { 'buffer_id' }),
  spec('save_source_buffer', 'Save ALL changes in the named ordinary buffer active before chat opened, including the user\'s changes. No target argument needed. Requires explicit approval with a disk-to-buffer preview; cannot name unnamed buffers.'),
  spec('create_file', 'Create a new workspace file on disk, in an existing directory (content at most 200KB). Requires confirmation; never overwrites.', {
    path = { type = 'string' }, content = { type = 'string' },
  }, { 'path', 'content' }),
}

local function file_buffer(path)
  local id = vim.fn.bufnr(path)
  if id ~= -1 and vim.api.nvim_buf_is_loaded(id) then
    if vim.bo[id].buftype ~= '' then return nil, 'Not an ordinary file buffer' end
    buffers.refresh(id)
    return id
  end
  id = vim.fn.bufadd(path)
  local ok, err = pcall(vim.fn.bufload, id)
  if not ok then return nil, tostring(err) end
  if vim.bo[id].buftype ~= '' then return nil, 'Not an ordinary file buffer' end
  return id
end

function M.execute(name, args, done, active, approve, reads, prepare, source, origin)
  local base = paths.root()
  if not base then return done('Error: workspace does not exist') end
  if name == 'save_buffer' or name == 'save_loaded_buffer' or name == 'save_source_buffer' then
    local id, err
    if args.path then
      local path
      path, err = resolve(args.path, false)
      if not path then return done('Error: ' .. err) end
      id = vim.fn.bufnr(path)
      if not buffers.valid(id) then return done('Error: saving requires an already-loaded buffer') end
    else
      id, err = buffers.target(args, source)
      if not id then return done('Error: ' .. err) end
    end
    if vim.bo[id].buftype ~= '' then return done('Error: Only ordinary file buffers can be saved') end
    local path = vim.api.nvim_buf_get_name(id)
    if path == '' then return done('Error: not saved: buffer has no file name') end
    if prepare and not prepare(path) then return done('Error: new project instructions discovered; review them before reissuing this save') end
    local tick, disk, eol = vim.api.nvim_buf_get_changedtick(id), buffers.disk_version(id), vim.bo[id].endofline
    local stat = vim.uv.fs_stat(path)
    if stat and stat.type ~= 'file' then return done('Error: not saved: target is not a regular file') end
    local file = io.open(path, 'rb')
    if stat and not file then return done('Error: not saved: cannot read disk contents for approval') end
    local before = file and file:read('*a') or ''
    if file then file:close() end
    if before:find('\0', 1, true) then return done('Error: not saved: binary files cannot be previewed safely') end
    local after = table.concat(vim.api.nvim_buf_get_lines(id, 0, -1, false), '\n') .. (vim.bo[id].endofline and '\n' or '')
    return approve('Save ALL current buffer changes, including user changes, to ' .. path .. '?', function()
      if not buffers.valid(id) or vim.api.nvim_buf_get_name(id) ~= path or vim.bo[id].buftype ~= ''
        or vim.api.nvim_buf_get_changedtick(id) ~= tick or buffers.disk_version(id) ~= disk or vim.bo[id].endofline ~= eol then
        return done('Error: not saved: file or buffer changed while awaiting confirmation')
      end
      local ok, failure = pcall(vim.api.nvim_buf_call, id, function() vim.cmd('silent keepalt write') end)
      if not ok then return done('Error: not saved: ' .. tostring(failure)) end
      if vim.bo[id].modified then return done('Error: not saved: buffer still has unwritten changes after write') end
      buffers.remember(id, reads)
      done('Saved ALL current buffer changes to ' .. path)
    end, { path = path, filetype = vim.bo[id].filetype, before = before, after = after,
      warning = 'SAVE ALL BUFFER CHANGES (including the user\'s edits)' })
  elseif name == 'read_file' or name == 'read_loaded_buffer' or name == 'read_source_buffer'
    or name == 'edit_file' or name == 'edit_loaded_buffer' or name == 'edit_source_buffer'
    or name == 'create_file' then
    local reading = name == 'read_file' or name == 'read_loaded_buffer' or name == 'read_source_buffer'
    local path, id, err
    if name ~= 'create_file' and args.path == nil then
      id, err = buffers.target(args, source)
      if not id then return done('Error: ' .. err) end
      path = vim.api.nvim_buf_get_name(id)
    else
      path, err = resolve(args.path, name ~= 'create_file', reading)
      if not path then return done('Error: ' .. err) end
    end
    local original_path = path
    if not reading and prepare and not prepare(path) then
      return done('Error: new project instructions discovered; review them before reissuing this write')
    end
    if name == 'create_file' then
      if type(args.content) ~= 'string' or #args.content > 200000 then return done('Error: content must be a string of at most 200KB') end
      local function has_unsaved_buffer()
        local id = vim.fn.bufnr(path)
        return id ~= -1 and vim.api.nvim_buf_is_loaded(id) and vim.bo[id].modified
      end
      if has_unsaved_buffer() then return done('Error: file has existing unwritten buffer changes') end
      return approve('Create ' .. path .. '?', function()
        local checked, failure = resolve(args.path, false)
        if not checked or checked ~= path then return done('Error: ' .. tostring(failure or 'Path changed')) end
        if has_unsaved_buffer() then return done('Error: file has existing unwritten buffer changes') end
        local fd, open_err = vim.uv.fs_open(path, 'wx', 420)
        if not fd then return done('Error: ' .. tostring(open_err)) end
        local written, write_err = vim.uv.fs_write(fd, args.content, 0)
        vim.uv.fs_close(fd)
        if not written or written ~= #args.content then return done('Error: ' .. tostring(write_err or 'Incomplete write')) end
        local existing = vim.fn.bufnr(path)
        if existing ~= -1 and vim.api.nvim_buf_is_loaded(existing) then buffers.refresh(existing) end
        done('Created ' .. path)
      end, { path = path, before = '', after = args.content })
    end
    if id then
      buffers.refresh(id)
    else
      id, err = file_buffer(path)
      if not id then return done('Error: ' .. err) end
    end
    if reading then
      local start, last = args.start_line or 1, args.end_line
      if not integer(start, 1) or last ~= nil and (not integer(last, 1) or last < start) then
        return done('Error: invalid range')
      end
      local result, read_err = buffers.read(id, start, last)
      if not result then return done('Error: ' .. read_err) end
      result.path, result.buffer_id = path, id
      buffers.remember(id, reads)
      return done(vim.json.encode(result))
    end
    if not buffers.was_read(id, reads) then return done('Error: read the current file before editing') end
    if not vim.bo[id].modifiable then return done('Error: buffer is not modifiable') end
    local lines = vim.api.nvim_buf_get_lines(id, 0, -1, false)
    local after, edit_error = edits.apply(lines, args.edits)
    if not after then return done('Error: ' .. edit_error) end
    local tick = vim.api.nvim_buf_get_changedtick(id)
    local was_modified = vim.bo[id].modified
    local disk_version = buffers.disk_version(id)
    local eol = vim.bo[id].endofline and '\n' or ''
    local preview = { path = path, filetype = vim.bo[id].filetype,
      before = table.concat(lines, '\n') .. eol, after = table.concat(after, '\n') .. eol }
    return approve('Replace in ' .. (path ~= '' and path or 'unnamed buffer ' .. id) .. '?', function()
      local checked = original_path
      if args.path then checked = resolve(args.path, true) end
      if checked ~= original_path or not buffers.valid(id) or vim.api.nvim_buf_get_name(id) ~= original_path
        or vim.bo[id].buftype ~= '' or vim.api.nvim_buf_get_changedtick(id) ~= tick or vim.bo[id].modified ~= was_modified
        or not vim.bo[id].modifiable or buffers.disk_version(id) ~= disk_version then
        return done('Error: file or buffer changed while awaiting confirmation')
      end
      local ok, edit_err = pcall(vim.api.nvim_buf_set_lines, id, 0, -1, false, after)
      if not ok then return done('Error: ' .. tostring(edit_err)) end
      local result = require('codeit.tools.workspace.write_buffer').finish(id, was_modified)
      buffers.remember(id, reads)
      done(result)
    end, preview)
  end
  done('Error: unknown tool ' .. tostring(name))
end

return M
