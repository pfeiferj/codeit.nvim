local M = {}
local spec = require('codeit.tools.spec')
local paths = require('codeit.tools.workspace.paths')
local runner = require('codeit.process')
local directory, scope, integer = paths.directory, paths.scope, paths.integer

M.specs = {
  spec('list_workspace_files', 'List workspace files respecting gitignore. Returns files, truncated, and next_offset; at most 200 files/20000 encoded bytes per page. Filtering occurs before pagination. Requires ripgrep.', {
    directory = { type = 'string', description = 'Optional existing workspace directory, default workspace root; returned paths stay workspace-relative' },
    query = { type = 'string', description = 'Optional literal substring of the relative file path' },
    offset = { type = 'integer', minimum = 0, description = 'Skip this many matching paths (default 0); use next_offset to continue' },
  }),
  spec('search_workspace', 'Search workspace DISK text, not unsaved buffers, with ripgrep (literal, case-sensitive). Returns filenames/line numbers and exit status (1 means no matches). Respects gitignore; skips binary files, files over 1MB, and lines over 300 columns. Output limited to 20000 bytes.', {
    query = { type = 'string', description = 'Nonempty literal text, at most 500 bytes' },
    directory = { type = 'string', description = 'Optional existing workspace directory; default root' },
    glob = { type = 'string', maxLength = 500, description = 'Optional filename/path glob, e.g. *.lua, src/*.lua or !*.lock; omit or use an empty string for no filter. Filtered after gitignore. Simple Vim glob syntax; braces unsupported.' },
    context_lines = { type = 'integer', minimum = 0, maximum = 20, description = 'Surrounding lines per match (default 0, maximum 20)' },
  }, { 'query' }),
}

function M.execute(name, args, done, active, approve, reads, prepare, source, origin)
  local base = paths.root()
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
    if args.glob and (args.glob == '!' or args.glob:find('%c') or args.glob:find('[{}]')) then
      return done('Error: glob must be simple glob syntax without controls or braces; omit or use an empty string for no filter')
    end
    -- Positive rg -g filters override gitignore. Filter the structured results
    -- instead so adding a glob never reveals ignored files.
    local argv = { 'rg', '--json', '--hidden', '-F', '--max-columns', '300', '--max-filesize', '1M',
      '-g', '!.git', '-C', tostring(args.context_lines or 0), '-e', args.query, '--', scope(dir, base) }
    return require('codeit.tools.workspace.search_output').run(argv, base, args, done, active)
  end
  done('Error: unknown tool ' .. tostring(name))
end

return M
