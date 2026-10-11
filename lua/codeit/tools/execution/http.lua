local M = {}
local spec = require('codeit.tools.spec')
local paths = require('codeit.tools.workspace.paths')
local runner = require('codeit.process')

M.specs = {
  spec('fetch_url', 'Fetch an HTTP(S) URL after confirmation, including redirects. Can access local/private networks; not a public-network sandbox. Returns HTTP status, final URL, body (up to 20000 bytes, truncated for larger pages), and explicit errors for non-2xx or transfer failures. Downloads are rate-limited to 200KB/s with a 15-second timeout; only a bounded body prefix is retained in memory. curl required.', {
    url = { type = 'string' },
  }, { 'url' }),
}

function M.execute(name, args, done, active, approve, reads, prepare, source, origin)
  local base = paths.root()
  if not base then return done('Error: workspace does not exist') end
  if name == 'fetch_url' then
    if type(args.url) ~= 'string' or not args.url:match('^https?://[^%s]+$') or args.url:find('%c')
      or #args.url > 4096 then return done('Error: expected HTTP(S) URL of at most 4096 bytes, without control characters') end
    return approve('Fetch ' .. args.url .. '? (May access local/private networks)', function()
      -- Stream the body separately from metadata; never buffer it all or write it
      -- to disk. Rate + time limits bound transfer work without rejecting ordinary
      -- documentation pages merely because their Content-Length exceeds 200KB.
      local chunks, bytes, truncated = {}, 0, false
      runner.run({ 'curl', '--disable', '--silent', '--show-error', '--location', '--proto', '=http,https',
        '--proto-redir', '=http,https', '--max-redirs', '3', '--max-time', '15',
        '--limit-rate', '200K', '--output', '-',
        '--write-out', '%{stderr}\nCODEIT_HTTP:%{http_code}\n%{url_effective}', '--url', args.url }, base, function(result)
        local errors, status, url = (result.stderr or ''):match('^(.*)\nCODEIT_HTTP:(%d%d%d)\n(.*)$')
        local failed = result.code ~= 0 or not status or tonumber(status) < 200 or tonumber(status) >= 300
        done((failed and 'Error: URL fetch failed\n' or '') .. vim.json.encode({
          http_status = tonumber(status), final_url = url, body = table.concat(chunks),
          truncated = truncated, exit_code = result.code,
          error = failed and (vim.trim(errors or result.stderr or '') ~= '' and vim.trim(errors or result.stderr)
            or (result.timed_out and 'Transfer timed out' or 'HTTP ' .. tostring(status))) or nil,
        }))
      end, active, { timeout_ms = 16000, on_stdout = function(chunk)
        local remaining = math.max(0, 20000 - bytes)
        if #chunk > remaining then truncated = true end
        local prefix = chunk:sub(1, remaining)
        if prefix ~= '' then chunks[#chunks + 1] = prefix; bytes = bytes + #prefix end
      end })
    end)
  end
  done('Error: unknown tool ' .. tostring(name))
end

return M
