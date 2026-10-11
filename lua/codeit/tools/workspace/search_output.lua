local M = {}

function M.run(argv, base, args, done, active)
  local runner = require('codeit.process')
  local pending, chunks, bytes, truncated, matches_returned, omitted = '', {}, 0, false, 0, false
  local glob = args.glob ~= '' and args.glob or nil
  local exclude = glob and glob:sub(1, 1) == '!'
  if exclude then glob = glob:sub(2) end
  local pattern = glob and vim.fn.glob2regpat(glob)
  runner.run(argv, base, function(result)
    result.stdout = table.concat(chunks)
    result.truncated = result.truncated or truncated
    if result.code == 0 and matches_returned == 0 then result.code = 1 end
    if omitted then result.stderr = (result.stderr or '') .. '\n[non-text or over-300-column results omitted]' end
    done(runner.format(result))
  end, active, { on_stdout = function(chunk)
    pending = pending .. chunk
    while true do
      local ending = pending:find('\n', 1, true)
      if not ending then break end
      local line = pending:sub(1, ending - 1)
      pending = pending:sub(ending + 1)
      if line == '' then break end
      local event = vim.json.decode(line)
      if event.type == 'match' or event.type == 'context' then
        local data = event.data
        local path, text = data.path.text, data.lines.text
        if path and text and #text <= 1204 and vim.fn.strdisplaywidth(text:gsub('\n$', '')) <= 300 then
          local candidate = glob and not glob:find('/', 1, true) and vim.fn.fnamemodify(path, ':t') or path:gsub('^%./', '')
          local matches = not pattern or vim.fn.match(candidate, pattern) >= 0
          if not pattern or matches ~= exclude then
            if event.type == 'match' then matches_returned = matches_returned + 1 end
            local separator = event.type == 'match' and ':' or '-'
            local output = path .. separator .. data.line_number .. separator .. text
            if output:sub(-1) ~= '\n' then output = output .. '\n' end
            if #output + bytes > 20000 then truncated = true end
            output = output:sub(1, math.max(0, 20000 - bytes))
            bytes = bytes + #output
            if output ~= '' then chunks[#chunks + 1] = output end
          end
        else omitted = true end
      end
    end
  end })
end

return M
