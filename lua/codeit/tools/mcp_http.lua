local M = {}
local max_bytes = 1024 * 1024

function M.url(value)
  if type(value) ~= 'string' or #value > 4096 or value:find('[%s%c#\\]') then return false end
  local scheme, host = value:match('^(https?)://([^/?]+)')
  return scheme ~= nil and not host:find('@', 1, true)
end

function M.header(name)
  return type(name) == 'string' and name:match("^[!#$%%&'*+%.%^_`|~%w-]+$") ~= nil
end

function M.env_name(name)
  return type(name) == 'string' and name:match('^[%a_][%w_]*$') ~= nil
end

function M.headers(config)
  local headers = vim.deepcopy(config.headers or {})
  for name, variable in pairs(config.header_env or {}) do
    local value = vim.env[variable]
    if not value or value == '' then return nil, 'Set $' .. variable .. ' to use this MCP endpoint' end
    headers[name] = value
  end
  if config.bearer_token_env then
    local token = vim.env[config.bearer_token_env]
    if not token or token == '' then return nil, 'Set $' .. config.bearer_token_env .. ' to use this MCP endpoint' end
    headers.Authorization = 'Bearer ' .. token
  end
  for name, value in pairs(headers) do
    if not M.header(name) or type(value) ~= 'string' or #value > 8192 or value:find('%c') then
      return nil, 'Invalid MCP HTTP header'
    end
  end
  return headers
end

local function quote(value)
  return '"' .. value:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\r', '\\r'):gsub('\n', '\\n'):gsub('\t', '\\t') .. '"'
end

-- Keep credentials off argv. Do not read .curlrc or follow redirects with configured headers.
function M.request(method, url, headers, body, timeout, done, stream)
  if not M.url(url) then done(nil, 'Invalid MCP HTTP URL'); return function() end end
  local args = { 'curl', '--disable', '--silent', '--include', '--no-buffer', '--suppress-connect-headers',
    '--globoff', '--proto', '=http,https', '--max-time', tostring(timeout / 1000), '--request', method, '--config', '-', '--', url }
  local config = {}
  for name, value in pairs(headers) do config[#config + 1] = 'header = ' .. quote(name .. ': ' .. value) end
  if body then
    local encoded = type(body) == 'string' and body or vim.json.encode(body)
    if encoded:sub(1, 1) == '@' then done(nil, 'Invalid MCP HTTP request body'); return function() end end
    config[#config + 1] = 'data-binary = ' .. quote(encoded)
  end
  local process, status, response_headers
  local output, preamble, bytes, finished = {}, '', 0, false
  local function cancel()
    if finished then return end
    finished = true
    if process then pcall(process.kill, process, 9) end
  end
  local function fail(err)
    cancel()
    done(nil, err)
  end
  local function consume(chunk)
    if not status then
      preamble = preamble .. chunk
      while true do
        local first, last = preamble:find('\r\n\r\n', 1, true)
        if not first then
          if #preamble > 32768 then fail('MCP HTTP headers too large') end
          return
        end
        local block = preamble:sub(1, first - 1)
        preamble = preamble:sub(last + 1)
        local code = tonumber(block:match('^HTTP/%S+ (%d%d%d)'))
        if not code then return fail('Invalid MCP HTTP response') end
        if code >= 200 then
          status, response_headers = code, {}
          for name, value in block:gmatch('\r\n([^:\r\n]+):[ \t]*([^\r\n]*)') do
            response_headers[name:lower()] = vim.trim(value)
          end
          chunk, preamble = preamble, ''
          break
        end
      end
    end
    if chunk == '' then return end
    if stream and status == 200 and (response_headers['content-type'] or ''):lower():match('^text/event%-stream') then
      stream(chunk, response_headers)
    else
      output[#output + 1] = chunk
    end
  end
  local ok, handle = pcall(vim.system, args, {
    stdin = table.concat(config, '\n') .. '\n', stderr = function() end,
    stdout = function(err, chunk)
      if finished then return end
      if err then return vim.schedule(function() if not finished then fail('Could not read MCP HTTP response') end end) end
      if not chunk then return end
      if bytes > max_bytes then return end
      bytes = bytes + #chunk
      if bytes > max_bytes then
        return vim.schedule(function() if not finished then fail('MCP HTTP response exceeds the size limit') end end)
      end
      vim.schedule(function() if not finished then consume(chunk) end end)
    end,
  }, vim.schedule_wrap(function(result)
    if finished then return end
    finished = true
    if result.code ~= 0 then
      return done(nil, result.code == 28 and 'MCP HTTP request timed out' or 'MCP HTTP connection failed (curl ' .. result.code .. ')')
    end
    if not status then return done(nil, 'Invalid MCP HTTP response') end
    done({ status = status, headers = response_headers, body = table.concat(output) })
  end))
  if ok then process = handle else fail('Could not start curl for MCP HTTP') end
  return cancel
end

return M
