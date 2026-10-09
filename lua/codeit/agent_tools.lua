local M = {}

local function spec(name, description, properties, required)
  return { type = 'function', ['function'] = { name = name, description = description,
    parameters = { type = 'object', properties = properties or vim.empty_dict(), required = required or {} } } }
end

M.specs = {
  spec('list_workspace_files', 'List files under the workspace, respecting gitignore. Requires ripgrep.', {
    query = { type = 'string', description = 'Optional literal substring of the relative file path' },
  }),
  spec('search_workspace', 'Search workspace text with ripgrep (literal, case-sensitive). Returns file names and line numbers.', {
    query = { type = 'string' },
  }, { 'query' }),
  spec('read_file', 'Read a workspace file (including unsaved Neovim buffer changes). Lines are 1-based and inclusive; omitted end_line reads to EOF and a range past EOF returns the available lines.', {
    path = { type = 'string' }, start_line = { type = 'integer' }, end_line = { type = 'integer' },
  }, { 'path' }),
  spec('edit_file', 'Replace exactly one occurrence of old_text in a workspace file buffer. Does not save the buffer. Requires confirmation; read the file first.', {
    path = { type = 'string' }, old_text = { type = 'string' }, new_text = { type = 'string' },
  }, { 'path', 'old_text', 'new_text' }),
  spec('create_file', 'Create a new workspace file on disk, in an existing directory. Requires confirmation; never overwrites.', {
    path = { type = 'string' }, content = { type = 'string' },
  }, { 'path', 'content' }),
  spec('run_command', 'Run a command in the workspace after user confirmation. Use for builds, tests, linters, etc. No shell interpolation; argv is an array.', {
    argv = { type = 'array', items = { type = 'string' }, description = 'Executable and arguments' },
  }, { 'argv' }),
  spec('get_diagnostics', 'Get Neovim LSP/linter diagnostics for loaded workspace file buffers.', {
    path = { type = 'string', description = 'Optional workspace file path to filter by' },
  }),
  spec('git_status', 'Read workspace Git status (short format).'),
  spec('git_diff', 'Read unstaged Git diff for workspace files. Does not include untracked files.', {
    path = { type = 'string', description = 'Optional workspace file path' },
  }),
  spec('fetch_url', 'Fetch a public HTTP(S) URL after user confirmation; returns truncated response text.', {
    url = { type = 'string' },
  }, { 'url' }),
}

local function output(text)
  text = text or ''
  if #text > 20000 then return text:sub(1, 20000) .. '\n[output truncated]' end
  return text
end

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
    return id
  end
  id = vim.fn.bufadd(path)
  local ok, err = pcall(vim.fn.bufload, id)
  if not ok then return nil, tostring(err) end
  if vim.bo[id].buftype ~= '' then return nil, 'Not an ordinary file buffer' end
  return id
end

local function process(argv, cwd, done, active)
  local finished, timed_out = false, false
  local ok, handle = pcall(vim.system, argv, { cwd = cwd, text = true }, function(result)
    vim.schedule(function()
      finished = true
      if active and not active() then return end
      done(output((result.stdout or '') .. (result.stderr or '')) .. '\n[exit code: ' .. tostring(result.code) .. ']'
        .. (timed_out and ' [timed out]' or ''))
    end)
  end)
  if not ok then return done('Error: ' .. tostring(handle)) end
  vim.defer_fn(function()
    if not finished then
      timed_out = true
      handle:kill(15)
    end
  end, 60000)
end

function M.execute(name, args, done, active, approve)
  local base = root()
  if not base then return done('Error: workspace does not exist') end
  if name == 'list_workspace_files' then
    if args.query ~= nil and type(args.query) ~= 'string' then return done('Error: query must be a string') end
    if vim.fn.executable('rg') ~= 1 then return done('Error: ripgrep is required') end
    local query = args.query or ''
    return process({ 'rg', '--files', '--hidden', '-g', '!.git', '.' }, base, function(result)
      local files = {}
      for line in result:gmatch('[^\n]+') do
        if line:sub(1, 2) == './' and line:find(query, 1, true) then files[#files + 1] = line:sub(3) end
        if #files >= 200 then break end
      end
      done(vim.json.encode(files))
    end, active)
  elseif name == 'search_workspace' then
    if type(args.query) ~= 'string' or args.query == '' or #args.query > 500 then return done('Error: invalid query') end
    if vim.fn.executable('rg') ~= 1 then return done('Error: ripgrep is required') end
    return process({ 'rg', '-n', '--hidden', '-F', '--max-columns', '300', '--max-filesize', '1M', '-g', '!.git', '-e', args.query, '.' }, base, done, active)
  elseif name == 'read_file' or name == 'edit_file' or name == 'create_file' then
    local path, err = resolve(args.path, name ~= 'create_file')
    if not path then return done('Error: ' .. err) end
    if name == 'create_file' then
      if type(args.content) ~= 'string' or #args.content > 200000 then return done('Error: content must be a string of at most 200KB') end
      return approve('Create ' .. path .. '?', function()
        local checked, failure = resolve(args.path, false)
        if not checked or checked ~= path then return done('Error: ' .. tostring(failure or 'Path changed')) end
        local fd, open_err = vim.uv.fs_open(path, 'wx', 420)
        if not fd then return done('Error: ' .. tostring(open_err)) end
        local written, write_err = vim.uv.fs_write(fd, args.content, 0)
        vim.uv.fs_close(fd)
        if not written or written ~= #args.content then return done('Error: ' .. tostring(write_err or 'Incomplete write')) end
        done('Created ' .. path)
      end, { path = path, before = '', after = args.content })
    end
    local id, failure = file_buffer(path)
    if not id then return done('Error: ' .. failure) end
    local count = vim.api.nvim_buf_line_count(id)
    if name == 'read_file' then
      local start = args.start_line or 1
      local last = args.end_line or math.max(start, count)
      if type(start) ~= 'number' or type(last) ~= 'number' or start % 1 ~= 0 or last % 1 ~= 0
        or start < 1 or last < start then return done('Error: invalid range') end
      local lines = vim.api.nvim_buf_get_lines(id, math.min(start - 1, count), math.min(last, count), false)
      return done(vim.json.encode({ path = path, start_line = start, end_line = start + #lines - 1,
        lines = lines, truncated = false }))
    end
    if type(args.old_text) ~= 'string' or args.old_text == '' or type(args.new_text) ~= 'string'
      or #args.old_text > 200000 or #args.new_text > 200000 then return done('Error: invalid replacement text') end
    if not vim.bo[id].modifiable then return done('Error: buffer is not modifiable') end
    local lines = vim.api.nvim_buf_get_lines(id, 0, -1, false)
    local text = table.concat(lines, '\n')
    if #text > 200000 then return done('Error: file is too large to edit') end
    local first = text:find(args.old_text, 1, true)
    if not first then return done('Error: old_text not found; read the file again') end
    if text:find(args.old_text, first + 1, true) then return done('Error: old_text is not unique') end
    local tick = vim.api.nvim_buf_get_changedtick(id)
    local replacement = text:sub(1, first - 1) .. args.new_text .. text:sub(first + #args.old_text)
    local new_lines = vim.split(replacement, '\n', { plain = true })
    local eol = vim.bo[id].endofline and '\n' or ''
    local preview = { path = path, filetype = vim.bo[id].filetype,
      before = text .. eol, after = table.concat(new_lines, '\n') .. eol }
    return approve('Replace in ' .. path .. '?', function()
      local checked = resolve(args.path, true)
      if checked ~= path or not vim.api.nvim_buf_is_valid(id) or not vim.api.nvim_buf_is_loaded(id)
        or vim.api.nvim_buf_get_changedtick(id) ~= tick or not vim.bo[id].modifiable then
        return done('Error: file or buffer changed while awaiting confirmation')
      end
      local ok, edit_err = pcall(vim.api.nvim_buf_set_lines, id, 0, -1, false, new_lines)
      done(ok and 'Applied edit to buffer (not saved)' or ('Error: ' .. tostring(edit_err)))
    end, preview)
  elseif name == 'run_command' then
    if type(args.argv) ~= 'table' or #args.argv == 0 or #args.argv > 40 then return done('Error: argv must be a nonempty array') end
    for _, arg in ipairs(args.argv) do
      if type(arg) ~= 'string' or arg == '' or #arg > 4096 then return done('Error: argv must contain nonempty strings') end
    end
    return approve('Run in ' .. base .. ': ' .. table.concat(args.argv, ' ') .. '?',
      function() process(args.argv, base, done, active) end)
  elseif name == 'get_diagnostics' then
    local filter
    if args.path ~= nil then
      local err
      filter, err = resolve(args.path, true)
      if not filter then return done('Error: ' .. err) end
    end
    local items = {}
    for _, id in ipairs(vim.api.nvim_list_bufs()) do
      local path = vim.api.nvim_buf_get_name(id)
      local checked = path ~= '' and resolve(path, true)
      if vim.api.nvim_buf_is_loaded(id) and vim.bo[id].buftype == '' and checked and within(path, base)
        and (not filter or path == filter) then
        for _, diagnostic in ipairs(vim.diagnostic.get(id)) do
          items[#items + 1] = { path = path, line = diagnostic.lnum + 1, column = diagnostic.col + 1,
            severity = diagnostic.severity, message = diagnostic.message, source = diagnostic.source }
          if #items >= 200 then break end
        end
      end
      if #items >= 200 then break end
    end
    return done(vim.json.encode(items))
  elseif name == 'git_status' or name == 'git_diff' then
    if vim.fn.executable('git') ~= 1 then return done('Error: git is required') end
    local argv = { 'git', '--no-pager' }
    if name == 'git_status' then
      vim.list_extend(argv, { 'status', '--short', '--untracked-files=all', '--', '.' })
    else
      vim.list_extend(argv, { 'diff', '--no-ext-diff', '--' })
      if args.path ~= nil then
        local path, err = resolve(args.path, true)
        if not path then return done('Error: ' .. err) end
        argv[#argv + 1] = path
      else
        argv[#argv + 1] = '.'
      end
    end
    return process(argv, base, done, active)
  elseif name == 'fetch_url' then
    if type(args.url) ~= 'string' or not args.url:match('^https?://[^%s]+$') then return done('Error: expected HTTP(S) URL') end
    return approve('Fetch ' .. args.url .. '?', function()
      process({ 'curl', '--silent', '--show-error', '--location', '--proto', '=http,https',
        '--proto-redir', '=http,https', '--max-redirs', '3', '--max-time', '15',
        '--max-filesize', '200000', args.url }, base, done, active)
    end)
  end
  done('Error: unknown tool ' .. tostring(name))
end

return M
