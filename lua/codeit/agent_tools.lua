local M = {}
local runner = require('codeit.process')
local buffers = require('codeit.file_buffer')
local edits = require('codeit.edits')

local replacement_properties = {
  old_text = { type = 'string', minLength = 1, maxLength = 200000 },
  new_text = { type = 'string', maxLength = 200000 },
  start_line = { type = 'integer', minimum = 1 }, end_line = { type = 'integer', minimum = 1 },
}

local function spec(name, description, properties, required)
  return { type = 'function', ['function'] = { name = name, description = description,
    parameters = { type = 'object', properties = properties or vim.empty_dict(),
      required = required or {}, additionalProperties = false } } }
end

M.specs = {
  spec('list_workspace_files', 'List workspace files respecting gitignore. Returns files, truncated, and next_offset; at most 200 files/20000 encoded bytes per page. Filtering occurs before pagination. Requires ripgrep.', {
    directory = { type = 'string', description = 'Optional existing workspace directory, default workspace root; returned paths stay workspace-relative' },
    query = { type = 'string', description = 'Optional literal substring of the relative file path' },
    offset = { type = 'integer', minimum = 0, description = 'Skip this many matching paths (default 0); use next_offset to continue' },
  }),
  spec('search_workspace', 'Search workspace DISK text, not unsaved buffers, with ripgrep (literal, case-sensitive). Returns filenames/line numbers and exit status (1 means no matches). Respects gitignore; skips binary files, files over 1MB, and lines over 300 columns. Output limited to 20000 bytes.', {
    query = { type = 'string', description = 'Nonempty literal text, at most 500 bytes' },
    directory = { type = 'string', description = 'Optional existing workspace directory; default root' },
    glob = { type = 'string', maxLength = 500, description = 'Optional filename/path glob, e.g. *.lua, src/*.lua or !*.lock; filtered after gitignore. Simple Vim glob syntax; braces unsupported.' },
    context_lines = { type = 'integer', minimum = 0, maximum = 20, description = 'Surrounding lines per match (default 0, maximum 20)' },
  }, { 'query' }),
  spec('read_file', 'Read a workspace path OR loaded ordinary buffer_id (including unnamed buffers); omit both to use the source buffer active before chat opened. Never specify both. Includes unsaved changes; clean buffers refresh from disk. Lines are 1-based/inclusive. At most 200 lines/20000 encoded bytes, even with end_line. Returns path, buffer_id, total_lines, truncated, next_start_line, modified; continue at next_start_line. Ranges past EOF return available lines.', {
    path = { type = 'string', description = 'Workspace file path; mutually exclusive with buffer_id' },
    buffer_id = { type = 'integer', minimum = 1, description = 'Loaded ordinary buffer ID; omit path and buffer_id for source buffer' },
    start_line = { type = 'integer', minimum = 1 }, end_line = { type = 'integer', minimum = 1 },
  }),
  spec('edit_file', 'Atomically replace exact text in one workspace path OR loaded ordinary buffer_id; omit both for source. Read first. Use old_text/new_text for one edit OR edits (1-50 replacements), never both. Every nonempty old_text must match once in the ORIGINAL revision; optional paired start_line/end_line scope each match. Overlaps/invalid matches reject the whole batch before approval. Total replacement text at most 200KB. One preview/approval, one buffer change; save clean named files, preserve unsaved/unnamed buffers. Disk save failure leaves the complete edit in the buffer.', {
    path = { type = 'string', description = 'Workspace path; mutually exclusive with buffer_id' },
    buffer_id = { type = 'integer', minimum = 1, description = 'Loaded ordinary buffer ID; omit both targets for source' },
    start_line = replacement_properties.start_line, end_line = replacement_properties.end_line,
    old_text = replacement_properties.old_text, new_text = replacement_properties.new_text,
    edits = { type = 'array', minItems = 1, maxItems = 50, items = {
      type = 'object', properties = replacement_properties, required = { 'old_text', 'new_text' }, additionalProperties = false,
    } },
  }),
  spec('save_buffer', 'Save ALL current changes in a named loaded ordinary buffer, including the user\'s changes, after explicit approval with a disk-to-buffer preview. Never implicitly save before tests. Workspace path OR buffer_id; omit both for source. Does not name unnamed buffers or force overwrite externally changed files. Returns saved/not-saved; saving uses normal Neovim write hooks.', {
    path = { type = 'string', description = 'Workspace path of an already-loaded buffer; mutually exclusive with buffer_id' },
    buffer_id = { type = 'integer', minimum = 1 },
  }),
  spec('create_file', 'Create a new workspace file on disk, in an existing directory (content at most 200KB). Requires confirmation; never overwrites.', {
    path = { type = 'string' }, content = { type = 'string' },
  }, { 'path', 'content' }),
  spec('run_command', 'Run a command against workspace DISK files after confirmation; unsaved edits are not included. No implicit shell. argv has 1-40 strings, each at most 4096 bytes; empty arguments allowed. Output limited to 20000 bytes, timeout 60 seconds. Cancellation terminates the process group on Unix.', {
    argv = { type = 'array', items = { type = 'string' }, description = 'Executable and arguments' },
  }, { 'argv' }),
  spec('get_diagnostics', 'Get existing LSP/linter diagnostics for loaded workspace files (max 200). Omit path/empty path for all. wait_ms (0-5000) optionally waits for a matching DiagnosticChanged event, not a guaranteed complete/fresh check. With wait_ms>0 returns diagnostics, updated, timed_out, waited_ms; otherwise returns the existing array. Never runs tests or starts a linter; empty results are not proof of success.', {
    path = { type = 'string', description = 'Optional workspace path; empty returns workspace diagnostics' },
    wait_ms = { type = 'integer', minimum = 0, maximum = 5000, description = 'Wait for a diagnostic update, at most this many milliseconds; default 0' },
  }),
  spec('git_status', 'Read workspace Git status (short format, disk state only). Output at most 20000 bytes with a truncation marker; filesystem-monitor programs disabled.'),
  spec('git_diff', 'Read tracked DISK changes, including deleted paths, not untracked/unsaved buffers. Default unstaged; staged=true compares index to HEAD. base optionally compares working tree (or index with staged=true) to a commit, e.g. HEAD or main. Only one commit revision, not ranges. No external diff/textconv/fsmonitor programs. Output max 20000 bytes. Omit path/empty path for all workspace diffs.', {
    path = { type = 'string', description = 'Optional workspace path; empty returns all diffs' },
    staged = { type = 'boolean', description = 'Compare staged index instead of working tree (default false)' },
    base = { type = 'string', minLength = 1, maxLength = 200, description = 'Optional single commit revision, resolved safely before diffing' },
  }),
  spec('fetch_url', 'Fetch an HTTP(S) URL after confirmation, including redirects. Can access local/private networks; not a public-network sandbox. Returns HTTP status, final URL, body (up to 20000 bytes), and explicit errors for non-2xx responses. curl required; timeout 15 seconds.', {
    url = { type = 'string' },
  }, { 'url' }),
}

local function root()
  return vim.uv.fs_realpath(vim.fn.getcwd())
end

local function within(path, base)
  return path == base or path:sub(1, #base + 1) == base .. '/'
end

local function resolve(path, must_exist)
  if type(path) ~= 'string' or path == '' or path:find('\0', 1, true) then return nil, 'Invalid path' end
  local base = root()
  if not base then return nil, 'Workspace does not exist' end
  local absolute = vim.fn.fnamemodify(path:sub(1, 1) == '/' and path or base .. '/' .. path, ':p'):gsub('/+$', '')
  if not within(absolute, base) or absolute == base then return nil, 'Path is outside the workspace' end
  local real = vim.uv.fs_realpath(absolute)
  if real then
    if not within(real, base) then return nil, 'Path resolves outside the workspace' end
    if not vim.uv.fs_stat(real) or vim.uv.fs_stat(real).type ~= 'file' then return nil, 'Not a regular file' end
    return absolute
  end
  if must_exist then return nil, 'File does not exist' end
  local parent = vim.uv.fs_realpath(vim.fn.fnamemodify(absolute, ':h'))
  if not parent or not within(parent, base) then return nil, 'Parent directory is outside the workspace or does not exist' end
  if vim.uv.fs_lstat(absolute) then return nil, 'Path already exists' end
  return absolute
end

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

local function directory(path, base)
  if path == nil or path == '' or path == '.' then return base end
  if type(path) ~= 'string' or path:find('\0', 1, true) then return nil, 'Invalid directory' end
  local absolute = vim.fs.normalize(path:sub(1, 1) == '/' and path or base .. '/' .. path)
  local real = vim.uv.fs_realpath(absolute)
  if not within(absolute, base) or not real or not within(real, base) then return nil, 'Directory is outside the workspace or does not exist' end
  if vim.uv.fs_stat(real).type ~= 'directory' then return nil, 'Not a directory' end
  return absolute
end

local function scope(path, base)
  return path == base and '.' or './' .. path:sub(#base + 2)
end

local function process(argv, cwd, done, active)
  return runner.run(argv, cwd, function(result) done(runner.format(result)) end, active)
end

local function integer(value, minimum)
  return type(value) == 'number' and value < math.huge and value % 1 == 0 and value >= minimum
end

local function git_path(path, base)
  -- Deleted files still have useful diffs. Validate existing ancestors, not existence.
  if type(path) ~= 'string' or path == '' or path:find('\0', 1, true) then return nil, 'Invalid path' end
  local absolute = vim.fs.normalize(path:sub(1, 1) == '/' and path or base .. '/' .. path)
  if not within(absolute, base) or absolute == base then return nil, 'Path is outside the workspace' end
  local parent = absolute
  while not vim.uv.fs_lstat(parent) do parent = vim.fn.fnamemodify(parent, ':h') end
  local real = vim.uv.fs_realpath(parent)
  if not real or not within(real, base) then return nil, 'Path resolves outside the workspace' end
  return absolute
end

function M.execute(name, args, done, active, approve, reads, prepare, source)
  local base = root()
  if not base then return done('Error: workspace does not exist') end
  if name == 'list_workspace_files' then
    if args.query ~= nil and type(args.query) ~= 'string' then return done('Error: query must be a string') end
    if vim.fn.executable('rg') ~= 1 then return done('Error: ripgrep is required') end
    local query, offset = args.query or '', args.offset or 0
    if not integer(offset, 0) then return done('Error: offset must be a nonnegative integer') end
    local dir, dir_err = directory(args.directory, base)
    if not dir then return done('Error: ' .. dir_err) end
    local files, pending, matched, bytes, full = {}, '', 0, 2, false
    return runner.run({ 'rg', '--files', '--null', '--sort', 'path', '--hidden', '-g', '!.git', '--', scope(dir, base) }, base, function(result)
      if result.code ~= 0 and not (result.code == 1 and matched == 0) or result.timed_out then
        return done('Error: file listing failed\n' .. runner.format(result))
      end
      done(vim.json.encode({ files = files, offset = offset, total_matches = matched,
        truncated = full, next_offset = full and offset + #files or nil }))
    end, active, { on_stdout = function(chunk)
      pending = pending .. chunk
      while true do
        local ending = pending:find('\0', 1, true)
        if not ending then break end
        local path = pending:sub(1, ending - 1):gsub('^%./', '')
        pending = pending:sub(ending + 1)
        if path:find(query, 1, true) then
          matched = matched + 1
          if matched > offset and not full then
            local size = #vim.json.encode(path) + 1
            if size > 19998 then error('A filename exceeds the encoded page limit; use an approved command to inspect it') end
            if #files >= 200 or bytes + size > 20000 then full = true
            else files[#files + 1], bytes = path, bytes + size end
          end
        end
      end
    end })
  elseif name == 'search_workspace' then
    if type(args.query) ~= 'string' or args.query == '' or #args.query > 500 or args.query:find('\0', 1, true) then
      return done('Error: query must be nonempty text of at most 500 bytes, without NUL')
    end
    if vim.fn.executable('rg') ~= 1 then return done('Error: ripgrep is required') end
    local dir, dir_err = directory(args.directory, base)
    if not dir then return done('Error: ' .. dir_err) end
    if args.glob and (args.glob == '' or args.glob == '!' or args.glob:find('%c') or args.glob:find('[{}]')) then
      return done('Error: glob must be nonempty simple glob syntax without controls or braces')
    end
    -- Positive rg -g filters override gitignore. Filter the structured results
    -- instead so adding a glob never reveals ignored files.
    local argv = { 'rg', '--json', '--hidden', '-F', '--max-columns', '300', '--max-filesize', '1M',
      '-g', '!.git', '-C', tostring(args.context_lines or 0), '-e', args.query, '--', scope(dir, base) }
    return require('codeit.workspace_search').run(argv, base, args, done, active)
  elseif name == 'save_buffer' then
    local id, err
    if args.path then
      local path
      path, err = resolve(args.path, false)
      if not path then return done('Error: ' .. err) end
      id = vim.fn.bufnr(path)
      if not buffers.valid(id) then return done('Error: save_buffer requires an already-loaded buffer') end
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
  elseif name == 'read_file' or name == 'edit_file' or name == 'create_file' then
    local path, id, err
    if name ~= 'create_file' and args.path == nil then
      id, err = buffers.target(args, source)
      if not id then return done('Error: ' .. err) end
      path = vim.api.nvim_buf_get_name(id)
    else
      path, err = resolve(args.path, name ~= 'create_file')
      if not path then return done('Error: ' .. err) end
    end
    local original_path = path
    if name ~= 'read_file' and prepare and not prepare(path) then
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
    if name == 'read_file' then
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
    local after, edit_error = edits.apply(lines, args.edits or { args })
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
      local result = require('codeit.write_buffer').finish(id, was_modified)
      buffers.remember(id, reads)
      done(result)
    end, preview)
  elseif name == 'run_command' then
    if type(args.argv) ~= 'table' or not vim.islist(args.argv) or #args.argv == 0 or #args.argv > 40 then
      return done('Error: argv must be an array of 1-40 strings')
    end
    for index, arg in ipairs(args.argv) do
      if type(arg) ~= 'string' or index == 1 and arg == '' or #arg > 4096 or arg:find('\0', 1, true) then
        return done('Error: invalid argv string (executable must be nonempty, each argument at most 4096 bytes, no NUL)')
      end
    end
    return approve('Run in ' .. base .. ': ' .. table.concat(args.argv, ' ') .. '?',
      function() process(args.argv, base, done, active) end)
  elseif name == 'get_diagnostics' then
    local filter
    if args.path ~= nil and args.path ~= '' then
      local err
      filter, err = resolve(args.path, true)
      if not filter then return done('Error: ' .. err) end
    end
    local function eligible(id)
      if not buffers.valid(id) or vim.bo[id].buftype ~= '' then return false end
      local path = vim.api.nvim_buf_get_name(id)
      return path ~= '' and resolve(path, true) and within(path, base) and (not filter or path == filter)
    end
    local function collect()
      local items, truncated = {}, false
      for _, id in ipairs(vim.api.nvim_list_bufs()) do
        if eligible(id) then
          for _, diagnostic in ipairs(vim.diagnostic.get(id)) do
            if #items == 200 then truncated = true; break end
            items[#items + 1] = { path = vim.api.nvim_buf_get_name(id), line = diagnostic.lnum + 1, column = diagnostic.col + 1,
              severity = diagnostic.severity, message = diagnostic.message, source = diagnostic.source }
          end
        end
      end
      return items, truncated
    end
    if not args.wait_ms or args.wait_ms == 0 then
      local items = collect()
      return done(vim.json.encode(items))
    end
    local started, finished = vim.uv.hrtime(), false
    local event, timer
    local function cleanup()
      if event then pcall(vim.api.nvim_del_autocmd, event) end
      if timer then timer:stop(); timer:close() end
    end
    local function finish(updated)
      if finished then return end
      finished = true
      cleanup()
      if active and not active() then return end
      local ok, items, truncated = pcall(collect)
      if not ok then return done('Error: diagnostics collection failed: ' .. tostring(items)) end
      done(vim.json.encode({ diagnostics = items, truncated = truncated, updated = updated, timed_out = not updated,
        waited_ms = math.floor((vim.uv.hrtime() - started) / 1000000),
        note = 'Observed updates are not proof of a complete or fresh check; no tests or linters were run.' }))
    end
    event = vim.api.nvim_create_autocmd('DiagnosticChanged', { callback = function(event_args)
      if not finished and eligible(event_args.buf) then vim.schedule(function() finish(true) end) end
    end })
    timer = vim.uv.new_timer()
    timer:start(10, 10, vim.schedule_wrap(function()
      if finished then return end
      if active and not active() then finished = true; cleanup(); return end
      if (vim.uv.hrtime() - started) / 1000000 >= args.wait_ms then finish(false) end
    end))
    return
  elseif name == 'git_status' or name == 'git_diff' then
    if vim.fn.executable('git') ~= 1 then return done('Error: git is required') end
    local argv = { 'git', '--no-pager', '--literal-pathspecs', '-c', 'core.fsmonitor=false' }
    if name == 'git_status' then
      vim.list_extend(argv, { 'status', '--short', '--untracked-files=all', '--', '.' })
    else
      vim.list_extend(argv, { 'diff', '--no-ext-diff', '--no-textconv' })
      if args.staged then argv[#argv + 1] = '--cached' end
      if args.base then
        if args.base:find('%c') or args.base:sub(1, 1) == '-' then return done('Error: invalid base revision') end
        local verify = { 'git', '--no-pager', '-c', 'core.fsmonitor=false', 'rev-parse', '--verify',
          '--end-of-options', args.base .. '^{commit}' }
        return runner.run(verify, base, function(result)
          local revision = vim.trim(result.stdout or '')
          if result.code ~= 0 or not revision:match('^%x+$') then
            return done('Error: base must resolve to one commit\n' .. runner.format(result))
          end
          -- The resolved hash cannot be interpreted as an option or path.
          argv[#argv + 1] = revision
          argv[#argv + 1] = '--'
          if args.path ~= nil and args.path ~= '' then
            local path, err = git_path(args.path, base)
            if not path then return done('Error: ' .. err) end
            argv[#argv + 1] = path
          else argv[#argv + 1] = '.' end
          process(argv, base, done, active)
        end, active)
      end
      argv[#argv + 1] = '--'
      if args.path ~= nil and args.path ~= '' then
        local path, err = git_path(args.path, base)
        if not path then return done('Error: ' .. err) end
        argv[#argv + 1] = path
      else
        argv[#argv + 1] = '.'
      end
    end
    return process(argv, base, done, active)
  elseif name == 'fetch_url' then
    if type(args.url) ~= 'string' or not args.url:match('^https?://[^%s]+$') or args.url:find('%c')
      or #args.url > 4096 then return done('Error: expected HTTP(S) URL of at most 4096 bytes, without control characters') end
    return approve('Fetch ' .. args.url .. '? (May access local/private networks)', function()
      -- A temporary body file keeps metadata separate and output memory bounded.
      local body_path = vim.fn.tempname()
      local fd, open_err = vim.uv.fs_open(body_path, 'wx', 384)
      if not fd then return done('Error: could not create fetch body file: ' .. tostring(open_err)) end
      vim.uv.fs_close(fd)
      runner.run({ 'curl', '--disable', '--silent', '--show-error', '--location', '--proto', '=http,https',
        '--proto-redir', '=http,https', '--max-redirs', '3', '--max-time', '15',
        '--max-filesize', '200000', '--output', body_path,
        '--write-out', '%{http_code}\n%{url_effective}', '--url', args.url }, base, function(result)
        local status, url = (result.stdout or ''):match('^(%d%d%d)\n(.*)$')
        local file = io.open(body_path, 'rb')
        local body = file and file:read(20001) or ''
        if file then file:close() end
        vim.uv.fs_unlink(body_path)
        local failed = result.code ~= 0 or not status or tonumber(status) < 200 or tonumber(status) >= 300
        done((failed and 'Error: URL fetch failed\n' or '') .. vim.json.encode({
          http_status = tonumber(status), final_url = url, body = body:sub(1, 20000),
          truncated = #body > 20000 or result.truncated, exit_code = result.code,
          error = failed and (result.stderr ~= '' and result.stderr or 'HTTP ' .. tostring(status)) or nil,
        }))
      end, active, { cleanup = function() vim.uv.fs_unlink(body_path) end })
    end)
  end
  done('Error: unknown tool ' .. tostring(name))
end

return M
