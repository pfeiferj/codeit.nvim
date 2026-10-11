local M = {}

local copilot_token
local copilot_expires = 0
local copilot_catalogs = {}
local limits, pending = {}, {}

local function log_error(config, err, detail)
  local dir = vim.fn.stdpath('state') .. '/codeit'
  local made = vim.fn.mkdir(dir, 'p')
  if made == 0 and vim.fn.isdirectory(dir) == 0 then return end
  local path = dir .. '/provider-errors.log'
  local fd = vim.uv.fs_open(path, 'a', 384) -- 0600 for new logs
  if not fd then return end
  local entry = string.format('[%s] %s/%s: %s\n', os.date('!%Y-%m-%dT%H:%M:%SZ'),
    tostring(config.provider), tostring(config.model), tostring(err))
  if detail and detail ~= '' then entry = entry .. 'Response: ' .. tostring(detail) .. '\n' end
  vim.uv.fs_write(fd, entry, -1)
  vim.uv.fs_close(fd)
end

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

local function http_json(args, options, callback, metadata, streaming, active)
  local retries = 0
  local function send()
    if active and not active() then return end
    local timer
    local function cleanup()
      if timer then timer:stop(); timer:close(); timer = nil end
    end
    local output, parser
    local attempt_options = vim.tbl_extend('force', {}, options)
    if streaming then
      output = {}
      parser = require('codeit.stream').new(streaming.responses, streaming.on_text)
      attempt_options.stdout = function(err, chunk)
        if err or not chunk then return end
        output[#output + 1] = chunk
        vim.schedule(function()
          if not active or active() then parser.push(chunk) end
        end)
      end
    end
    local process = vim.system(args, attempt_options, function(result)
      vim.schedule(function()
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
          if streamed then return callback(response, err, err and data or nil) end
        end
        local ok, decoded = pcall(vim.json.decode, data)
        if tonumber(status) < 200 or tonumber(status) >= 300 then
          local err = ok and type(decoded) == 'table' and decoded.error or nil
          if type(err) == 'table' then err = err.message end
          return callback(nil, 'HTTP ' .. status .. ': ' .. tostring(err or data:sub(1, 300)), data)
        end
        if not ok or (metadata and type(decoded) ~= 'table') then
          return callback(nil, metadata and 'Invalid model metadata response'
            or 'Invalid JSON response: ' .. data:sub(1, 300), data)
        end
        callback(decoded)
      end)
    end)
    if active then
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

local function request(url, headers, body, callback, streaming, active)
  local args = { 'curl', '--silent', '--show-error', '--include', '--max-time', '120', '--request', 'POST', '--write-out', '\n%{http_code}' }
  if streaming then args[#args + 1] = '--no-buffer' end
  for _, header in ipairs(headers) do
    vim.list_extend(args, { '--header', header })
  end
  vim.list_extend(args, { '--data-binary', '@-', url })
  http_json(args, { stdin = vim.json.encode(body), text = true }, callback, false, streaming, active)
end

local function get_json(url, headers, callback)
  local args = { 'curl', '--silent', '--show-error', '--include', '--max-time', '30', '--write-out', '\n%{http_code}' }
  for _, header in ipairs(headers) do vim.list_extend(args, { '--header', header }) end
  args[#args + 1] = url
  http_json(args, { text = true }, callback, true)
end

local function github_token()
  for _, name in ipairs({ 'COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN' }) do
    local token = vim.env[name]
    if token and token ~= '' then return token end
  end
  -- Copilot OAuth credentials are not interchangeable with arbitrary PATs or gh tokens.
  local config_dir = vim.env.XDG_CONFIG_HOME
  if not config_dir or config_dir == '' then
    config_dir = vim.fn.has('win32') == 1 and vim.env.LOCALAPPDATA or vim.fn.expand('~/.config')
  end
  if config_dir and config_dir ~= '' then
    for _, name in ipairs({ 'apps.json', 'hosts.json' }) do
      local ok, credentials = pcall(function()
        return vim.json.decode(table.concat(vim.fn.readfile(config_dir .. '/github-copilot/' .. name), '\n'))
      end)
      if ok and type(credentials) == 'table' then
        for _, host in ipairs(vim.fn.sort(vim.tbl_keys(credentials))) do
          local entry = credentials[host]
          if type(host) == 'string' and (host == 'github.com' or host:match('^github%.com:')) and type(entry) == 'table'
            and type(entry.oauth_token) == 'string' and entry.oauth_token ~= '' then
            return entry.oauth_token
          end
        end
      end
    end
  end
  if vim.fn.executable('gh') == 1 then
    local result = vim.system({ 'gh', 'auth', 'token', '--hostname', 'github.com' }, { text = true }):wait()
    if result.code == 0 then return vim.trim(result.stdout or '') end
  end
end

local function copilot_auth(callback)
  if copilot_token and os.time() < copilot_expires - 60 then
    callback(copilot_token)
    return
  end
  local token = github_token()
  if not token or token == '' then
    callback(nil, 'Copilot requires a Copilot login (copilot.vim/copilot.lua), COPILOT_GITHUB_TOKEN, '
      .. 'GH_TOKEN, GITHUB_TOKEN, or `gh auth login`')
    return
  end
  -- The token exchange is specific to GitHub Copilot and requires an entitled GitHub account.
  vim.system({ 'curl', '--silent', '--show-error', '--max-time', '30', '--write-out', '\n%{http_code}',
    '--header', 'Authorization: token ' .. token,
    '--header', 'Accept: application/json', 'https://api.github.com/copilot_internal/v2/token' }, { text = true }, function(result)
    vim.schedule(function()
      local function fail(reason, response)
        -- Never log the exchange body: it may contain either credential, even on failure.
        reason = reason:gsub(vim.pesc(token), '[redacted]')
        if type(response) == 'table' and type(response.token) == 'string' and response.token ~= '' then
          reason = reason:gsub(vim.pesc(response.token), '[redacted]')
        end
        callback(nil, 'Copilot token exchange failed: ' .. reason)
      end
      if result.code ~= 0 then
        return fail((result.stderr or '') ~= '' and result.stderr or 'curl exited with code ' .. result.code)
      end
      local data, status = (result.stdout or ''):match('^(.*)\n(%d%d%d)$')
      if not data then return fail('Invalid HTTP response') end
      local ok, response = pcall(vim.json.decode, data)
      if tonumber(status) < 200 or tonumber(status) >= 300 then
        local message = ok and type(response) == 'table' and (response.error or response.message)
        if type(message) == 'table' then message = message.message or message.msg end
        local reason = 'HTTP ' .. status
        if type(message) == 'string' and message ~= '' then reason = reason .. ': ' .. message end
        if status == '401' or status == '403' then
          reason = reason .. '. Sign in with copilot.vim/copilot.lua or set COPILOT_GITHUB_TOKEN to a Copilot OAuth token; '
            .. 'GitHub CLI/PAT tokens may not be accepted. Check that the account has Copilot access'
        end
        return fail(reason, response)
      end
      if not ok or type(response) ~= 'table' then return fail('Invalid JSON response') end
      if type(response.token) ~= 'string' or response.token == '' then
        return fail('Response has no valid Copilot token')
      end
      copilot_token = response.token
      copilot_expires = tonumber(response.expires_at) or (os.time() + 300)
      callback(copilot_token)
    end)
  end)
end

local function copilot_url(options)
  local host = options and options.api_host
  if host == nil or host == '' then host = 'api.githubcopilot.com' end
  -- Restrict destinations so a typo cannot send a Copilot bearer token to an arbitrary host.
  if not vim.tbl_contains(require('codeit.settings').copilot_hosts, host) then
    return nil, 'Invalid Copilot API host: ' .. tostring(host)
  end
  return 'https://' .. host
end

local function copilot_endpoint(model)
  local endpoints = model and model.supported_endpoints
  -- Older catalogs do not report endpoints; retain their chat-completions behavior.
  if endpoints == nil or endpoints == vim.NIL then return '/chat/completions' end
  if type(endpoints) == 'table' then
    if vim.tbl_contains(endpoints, '/chat/completions') then return '/chat/completions' end
    if vim.tbl_contains(endpoints, '/responses') then return '/responses' end
  end
  return nil, 'Copilot model ' .. tostring(model.id)
    .. ' does not advertise a supported chat endpoint (/chat/completions or /responses); choose another model'
end

--- Fetch available models from the selected backend (no completion request).
--- Optional options uses the same per-provider request options as chat.
function M.models(provider, callback, options)
  local function finish(response, err, detail)
    if err then return callback(nil, err, detail) end
    local entries = response.data or response.models or response
    if type(entries) ~= 'table' or not vim.islist(entries) then
      return callback(nil, 'Invalid model catalog')
    end
    local models = {}
    for _, entry in ipairs(entries) do
      if type(entry) == 'table' and type(entry.id) == 'string' then models[#models + 1] = entry end
    end
    table.sort(models, function(a, b) return a.id < b.id end)
    if provider == 'copilot' then
      local catalog = {}
      for _, model in ipairs(models) do catalog[model.id] = model end
      copilot_catalogs[copilot_url(options)] = catalog
    end
    callback(models)
  end
  if provider == 'openrouter' then
    local token = vim.env.OPENROUTER_API_KEY
    if not token or token == '' then return callback(nil, 'Set OPENROUTER_API_KEY to use OpenRouter') end
    get_json('https://openrouter.ai/api/v1/models', { 'Authorization: Bearer ' .. token }, finish)
  elseif provider == 'copilot' then
    local url, url_error = copilot_url(options)
    if not url then return callback(nil, url_error) end
    copilot_auth(function(token, err)
      if err then return callback(nil, err) end
      get_json(url .. '/models', {
        'Authorization: Bearer ' .. token,
        -- The versioned catalog exposes billing.token_prices.
        'X-GitHub-Api-Version: 2026-08-01',
        'Editor-Version: Neovim/0.12.0',
        'Editor-Plugin-Version: codeit.nvim/0.1.0',
        'Copilot-Integration-Id: vscode-chat',
        'Openai-Intent: conversation-panel',
      }, finish)
    end)
  else
    callback(nil, 'Unknown provider: ' .. tostring(provider))
  end
end

--- Fetch model-specific OpenRouter upstream endpoints, including their pricing.
function M.endpoints(model, callback)
  local token = vim.env.OPENROUTER_API_KEY
  if not token or token == '' then return callback(nil, 'Set OPENROUTER_API_KEY to use OpenRouter') end
  if type(model) ~= 'string' then return callback(nil, 'Invalid OpenRouter model ID') end
  -- Routing variants share the base model's endpoint catalog.
  model = model:gsub(':nitro$', ''):gsub(':floor$', '')
  local author, slug = model:match('^([^/]+)/([^/]+)$')
  if not author then return callback(nil, 'OpenRouter model IDs must include author/model') end
  local function encode(value)
    return (value:gsub('[^%w%-%._~]', function(char) return string.format('%%%02X', char:byte()) end))
  end
  local url = 'https://openrouter.ai/api/v1/models/' .. encode(author) .. '/' .. encode(slug) .. '/endpoints'
  get_json(url, { 'Authorization: Bearer ' .. token }, function(response, err, detail)
    if err then return callback(nil, err, detail) end
    local entries = type(response.data) == 'table' and response.data.endpoints
    if type(entries) ~= 'table' or not vim.islist(entries) then
      return callback(nil, 'Invalid model endpoint catalog')
    end
    local endpoints = {}
    for _, entry in ipairs(entries) do
      if type(entry) == 'table' and type(entry.tag) == 'string' and entry.tag ~= ''
        and (entry.status == nil or entry.status == vim.NIL or tonumber(entry.status) == 0) then
        endpoints[#endpoints + 1] = entry
      end
    end
    table.sort(endpoints, function(a, b) return a.tag < b.tag end)
    callback(endpoints)
  end)
end

--- Resolve a model's context window; failures are cached for this session.
function M.context_limit(config, callback)
  local key = config.provider .. '/' .. config.model
  if config.provider == 'copilot' then
    local url, err = copilot_url(config.options)
    if not url then return callback(nil, err) end
    key = key .. '/' .. url
  end
  if limits[key] ~= nil then return callback(limits[key] or nil) end
  if pending[key] then
    pending[key][#pending[key] + 1] = callback
    return
  end
  pending[key] = { callback }
  local function finish(limit, err, detail)
    if type(limit) ~= 'number' or limit <= 0 or limit == math.huge or limit ~= limit then
      limit = nil
      err = err or ('no context limit reported for ' .. config.model)
    end
    if err then log_error(config, err, detail) end
    limits[key] = limit or false
    local callbacks = pending[key]
    pending[key] = nil
    for _, done in ipairs(callbacks) do done(limit, err) end
  end
  local function extract(response)
    local models = response.data or response.models or response
    if type(models) ~= 'table' then return finish(nil) end
    for _, entry in ipairs(models) do
      if type(entry) == 'table' and entry.id == config.model then
        if config.provider == 'openrouter' then
          return finish(tonumber(entry.context_length))
        end
        local limits_data = type(entry.capabilities) == 'table' and entry.capabilities.limits or nil
        if type(limits_data) == 'table' then
          return finish(tonumber(limits_data.max_context_window_tokens or limits_data.max_prompt_tokens))
        end
        return finish(nil)
      end
    end
    finish(nil, 'model not found in provider metadata: ' .. config.model)
  end
  M.models(config.provider, function(models, err, detail)
    if err then return finish(nil, err, detail) end
    extract(models)
  end, config.options)
end

local function cached_tokens(usage)
  if not usage then return nil end
  local details = usage.prompt_tokens_details or usage.input_tokens_details
  return type(details) == 'table' and details.cached_tokens or nil
end

-- Normalize Copilot's two token-usage formats and server-reported charge.
-- Keep cost in USD like OpenRouter: 1e9 nano-AIU = 1 credit = $0.01.
local function copilot_usage(response)
  local usage = type(response.usage) == 'table' and response.usage or nil
  local billing = type(response.copilot_usage) == 'table' and response.copilot_usage or nil
  if not usage and not billing then return nil end
  local nano = billing and billing.total_nano_aiu
  nano = (type(nano) == 'number' or type(nano) == 'string') and tonumber(nano) or nil
  return {
    cost = nano and nano >= 0 and nano < math.huge and nano / 100000000000 or nil,
    prompt_tokens = usage and (usage.prompt_tokens or usage.input_tokens),
    completion_tokens = usage and (usage.completion_tokens or usage.output_tokens),
    total_tokens = usage and usage.total_tokens,
    cached_tokens = cached_tokens(usage),
  }
end

--- Send a chat request, normalizing provider responses. callback(message, error, usage).
function M.chat(config, messages, tools, callback, on_text, active)
  local on_result = callback
  callback = function(message, err, usage, detail)
    if active and not active() then return end
    if err then log_error(config, err, detail) end
    on_result(message, err, usage)
  end
  local function send(url, token, extra_headers, endpoint)
    if active and not active() then return end
    local headers = { 'Content-Type: application/json', 'Authorization: Bearer ' .. token }
    vim.list_extend(headers, extra_headers or {})
    local body = { model = config.model }
    if endpoint == '/responses' then
      local err
      body, err = require('codeit.copilot_responses').body(config.model, messages, tools)
      if err then return callback(nil, err) end
    else
      body.messages = {}
      for _, message in ipairs(messages) do
        local copy = vim.tbl_extend('force', {}, message)
        -- Responses replay metadata is private, not a chat-completions message field.
        copy._copilot_reasoning = nil
        body.messages[#body.messages + 1] = copy
      end
    end
    if config.max_output_tokens then
      if endpoint == '/responses' then body.max_output_tokens = config.max_output_tokens
      elseif config.provider == 'openrouter' then body.max_tokens = config.max_output_tokens
      else body.max_completion_tokens = config.max_output_tokens end
    end
    if config.provider == 'openrouter' then
      body.usage = { include = true }
      local options = config.options or {}
      if options.preferred_provider and options.preferred_provider ~= '' then
        body.provider = { order = { options.preferred_provider } }
      end
      if options.service_tier and options.service_tier ~= '' then body.service_tier = options.service_tier end
      if options.effort and options.effort ~= '' then body.reasoning = { effort = options.effort } end
    end
    if endpoint ~= '/responses' and tools and #tools > 0 then
      body.tools = tools
      body.tool_choice = 'auto'
    end
    if on_text then
      body.stream = true
      if endpoint ~= '/responses' then body.stream_options = { include_usage = true } end
    end
    request(url, headers, body, function(response, err, detail)
      if err then return callback(nil, err, nil, detail) end
      if endpoint == '/responses' then
        local message, failure = require('codeit.copilot_responses').message(response)
        return callback(message, failure, (not failure or config.max_output_tokens) and copilot_usage(response) or nil,
          failure and vim.json.encode(response) or nil)
      end
      local choice = type(response) == 'table' and type(response.choices) == 'table' and response.choices[1]
      if type(choice) ~= 'table' or type(choice.message) ~= 'table' then
        return callback(nil, 'Response has no assistant message', nil, vim.json.encode(response))
      end
      if config.max_output_tokens and choice.finish_reason == 'length' then
        return callback(nil, 'Summary output reached its token cap',
          config.provider == 'copilot' and copilot_usage(response) or response.usage, vim.json.encode(response))
      end
      local message = choice.message
      if type(message.refusal) == 'string'
        and (message.content == nil or message.content == vim.NIL or message.content == ''
          or (type(message.content) == 'table' and vim.islist(message.content) and #message.content == 0)) then
        message.content = message.refusal
      end
      if config.provider == 'openrouter' then
        local usage = type(response.usage) == 'table' and response.usage or nil
        callback(message, nil, {
          cost = usage and usage.cost,
          prompt_tokens = usage and usage.prompt_tokens,
          completion_tokens = usage and usage.completion_tokens,
          total_tokens = usage and usage.total_tokens,
          cached_tokens = cached_tokens(usage),
        })
      else
        callback(message, nil, copilot_usage(response))
      end
    end, on_text and { responses = endpoint == '/responses', on_text = on_text } or nil, active)
  end

  if config.provider == 'openrouter' then
    local key = vim.env.OPENROUTER_API_KEY
    if not key or key == '' then return callback(nil, 'Set OPENROUTER_API_KEY to use OpenRouter') end
    send('https://openrouter.ai/api/v1/chat/completions', key, {
      'HTTP-Referer: https://github.com/codeit-nvim/codeit.nvim',
      'X-Title: codeit.nvim',
    })
  elseif config.provider == 'copilot' then
    local url, url_error = copilot_url(config.options)
    if not url then return callback(nil, url_error) end
    local function route()
      local endpoint, endpoint_error = copilot_endpoint(copilot_catalogs[url][config.model])
      if not endpoint then return callback(nil, endpoint_error) end
      copilot_auth(function(token, err)
        if err then return callback(nil, err) end
        send(url .. endpoint, token, {
          'X-GitHub-Api-Version: 2026-08-01',
          'Editor-Version: Neovim/0.12.0',
          'Editor-Plugin-Version: codeit.nvim/0.1.0',
          'Copilot-Integration-Id: vscode-chat',
          'Openai-Intent: conversation-panel',
        }, endpoint)
      end)
    end
    if copilot_catalogs[url] then return route() end
    -- Manual model IDs and secondary tasks also need endpoint metadata, not just the picker.
    M.models('copilot', function(_, err, detail)
      if err then return callback(nil, err, nil, detail) end
      route()
    end, config.options)
  else
    callback(nil, 'Unknown provider: ' .. tostring(config.provider))
  end
end

return M
