local M = {}

local function retry_after(headers)
  local value
  for line in headers:gmatch('[^\r\n]+') do
    local name, content = line:match('^([^:]+):%s*(.-)%s*$')
    if name and name:lower() == 'retry-after' then value = content end
  end
  if not value then return end
  if value:match('^%d+$') then return tonumber(value) end
  local day, month, year, hour, minute, second = value:match(
    '^%a+, (%d%d) (%a+) (%d%d%d%d) (%d%d):(%d%d):(%d%d) GMT$')
  local months = { Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6,
    Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12 }
  if not day or not months[month] then return end
  local now = os.time()
  local utc = os.date('!*t', now)
  utc.isdst = false
  local offset = os.difftime(now, os.time(utc))
  local date = os.time({ year = tonumber(year), month = months[month], day = tonumber(day),
    hour = tonumber(hour), min = tonumber(minute), sec = tonumber(second), isdst = false })
  return date and math.max(0, date + offset - now) or nil
end

local function http_json(args, options, callback, metadata, streaming, active, model)
  local retries = 0
  local function send()
    if active and not active() then return end
    local timer, deadline_cleanup, activity
    local finished = false
    local function cleanup()
      if timer then timer:stop(); timer:close(); timer = nil end
      if deadline_cleanup then deadline_cleanup(); deadline_cleanup = nil end
    end
    local output, parser
    local attempt_options = vim.tbl_extend('force', {}, options)
    if streaming then
      output = {}
      parser = require('codeit.providers.protocols.stream').new(streaming.responses, streaming.on_text, function()
        if activity then activity() end
        if streaming.on_activity then streaming.on_activity() end
      end, streaming.on_codex_usage)
      attempt_options.stdout = function(err, chunk)
        if finished or err or not chunk then return end
        output[#output + 1] = chunk
        vim.schedule(function()
          if not finished and (not active or active()) then parser.push(chunk) end
        end)
      end
    end
    local process = vim.system(args, attempt_options, function(result)
      vim.schedule(function()
        if finished then return end
        finished = true
        cleanup()
        if active and not active() then return end
        if output then result.stdout = table.concat(output) end
        if result.code ~= 0 then
          return callback(nil, (result.stderr or '') ~= '' and result.stderr or 'curl exited with code ' .. result.code)
        end
        local data, status = (result.stdout or ''):match('^(.*)\n(%d%d%d)$')
        if not data then return callback(nil, 'Invalid HTTP response', result.stdout or result.stderr) end
        local headers = ''
        -- curl can emit proxy CONNECT and informational headers before the final response.
        while data:match('^HTTP/%S+ %d%d%d') do
          local block, rest = data:match('^(.-)\r\n\r\n(.*)$')
          if not block then block, rest = data:match('^(.-)\n\n(.*)$') end
          if not block then break end
          headers, data = block, rest
        end
        if status == '429' and retries < 3 then
          local delay = retry_after(headers) or 2 ^ (retries + 1)
          -- Do not retry earlier than requested, or leave a chat waiting indefinitely.
          if delay <= 60 then
            retries = retries + 1
            return vim.defer_fn(send, math.ceil(delay * 1000))
          end
        end
        if parser and tonumber(status) >= 200 and tonumber(status) < 300 then
          local response, err, streamed = parser.finish()
          if streamed then return callback(response, err, err and data or nil, headers) end
        end
        local ok, decoded = pcall(vim.json.decode, data)
        if tonumber(status) < 200 or tonumber(status) >= 300 then
          local err = ok and type(decoded) == 'table' and decoded.error or nil
          if type(err) == 'table' then err = err.message end
          return callback(nil, 'HTTP ' .. status .. ': ' .. tostring(err or data:sub(1, 300)), data, headers)
        end
        if not ok or (metadata and type(decoded) ~= 'table') then
          return callback(nil, metadata and 'Invalid model metadata response'
            or 'Invalid JSON response: ' .. data:sub(1, 300), data)
        end
        callback(decoded, nil, nil, headers)
      end)
    end)
    if not metadata then
      deadline_cleanup, activity = require('codeit.providers.deadline').start(function(err)
        if finished then return end
        finished = true
        cleanup()
        if process then pcall(process.kill, process, 9) end
        if err and (not active or active()) then callback(nil, err) end
      end, active, model)
    elseif active then
      timer = vim.uv.new_timer()
      timer:start(50, 50, vim.schedule_wrap(function()
        if not active() then
          cleanup()
          if process then process:kill(9) end
        end
      end))
    end
  end
  send()
end

function M.post(url, headers, body, callback, streaming, active)
  local args = { 'curl', '--silent', '--show-error', '--include', '--connect-timeout', '30',
    '--max-time', '0', '--request', 'POST', '--write-out', '\n%{http_code}' }
  if streaming then vim.list_extend(args, { '--no-buffer', '--header', 'Accept: text/event-stream' }) end
  for _, header in ipairs(headers) do
    vim.list_extend(args, { '--header', header })
  end
  vim.list_extend(args, { '--data-binary', '@-', url })
  http_json(args, { stdin = vim.json.encode(body), text = true }, callback, false, streaming, active, body.model)
end

function M.get(url, headers, callback)
  local args = { 'curl', '--silent', '--show-error', '--include', '--max-time', '60', '--write-out', '\n%{http_code}' }
  for _, header in ipairs(headers) do vim.list_extend(args, { '--header', header }) end
  args[#args + 1] = url
  http_json(args, { text = true }, callback, true)
end

return M
