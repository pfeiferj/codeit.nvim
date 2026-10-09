local M = {}

local copilot_token
local copilot_expires = 0
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

local function request(url, headers, body, callback)
  local args = { 'curl', '--silent', '--show-error', '--max-time', '120', '--request', 'POST', '--write-out', '\n%{http_code}' }
  for _, header in ipairs(headers) do
    vim.list_extend(args, { '--header', header })
  end
  vim.list_extend(args, { '--data-binary', '@-', url })
  vim.system(args, { stdin = vim.json.encode(body), text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil, (result.stderr or '') ~= '' and result.stderr or 'curl exited with code ' .. result.code)
        return
      end
      local data, status = (result.stdout or ''):match('^(.*)\n(%d%d%d)$')
      if not data then
        callback(nil, 'Invalid HTTP response', result.stdout or result.stderr)
        return
      end
      local ok, decoded = pcall(vim.json.decode, data)
      if not ok then
        callback(nil, 'Invalid JSON response: ' .. data:sub(1, 300), data)
      elseif tonumber(status) < 200 or tonumber(status) >= 300 then
        local message = type(decoded) == 'table' and decoded.error
        if type(message) == 'table' then message = message.message end
        callback(nil, 'HTTP ' .. status .. ': ' .. tostring(message or data:sub(1, 300)), data)
      else
        callback(decoded)
      end
    end)
  end)
end

local function get_json(url, headers, callback)
  local args = { 'curl', '--silent', '--show-error', '--max-time', '30', '--write-out', '\n%{http_code}' }
  for _, header in ipairs(headers) do vim.list_extend(args, { '--header', header }) end
  args[#args + 1] = url
  vim.system(args, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        return callback(nil, (result.stderr or '') ~= '' and result.stderr or 'curl exited with code ' .. result.code)
      end
      local data, status = (result.stdout or ''):match('^(.*)\n(%d%d%d)$')
      if not data then return callback(nil, 'Invalid HTTP response', result.stdout or result.stderr) end
      local ok, decoded = pcall(vim.json.decode, data)
      if not ok or type(decoded) ~= 'table' then return callback(nil, 'Invalid model metadata response', data) end
      if tonumber(status) < 200 or tonumber(status) >= 300 then
        local err = decoded.error
        if type(err) == 'table' then err = err.message end
        return callback(nil, 'HTTP ' .. status .. ': ' .. tostring(err or data:sub(1, 300)), data)
      end
      callback(decoded)
    end)
  end)
end

local function github_token()
  local token = vim.env.GH_TOKEN or vim.env.GITHUB_TOKEN
  if token and token ~= '' then return token end
  if vim.fn.executable('gh') == 1 then
    local result = vim.system({ 'gh', 'auth', 'token' }, { text = true }):wait()
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
    callback(nil, 'Copilot requires GH_TOKEN, GITHUB_TOKEN, or `gh auth login`')
    return
  end
  -- The token exchange is specific to GitHub Copilot and requires an entitled GitHub account.
  vim.system({ 'curl', '--silent', '--show-error', '--max-time', '30', '--header', 'Authorization: token ' .. token,
    '--header', 'Accept: application/json', 'https://api.github.com/copilot_internal/v2/token' }, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil, result.stderr or 'Copilot token exchange failed')
        return
      end
      local ok, response = pcall(vim.json.decode, result.stdout or '')
      if not ok or type(response) ~= 'table' or not response.token then
        callback(nil, 'Copilot token exchange failed (check your Copilot access and GitHub credentials)')
        return
      end
      copilot_token = response.token
      copilot_expires = tonumber(response.expires_at) or (os.time() + 300)
      callback(copilot_token)
    end)
  end)
end

--- Fetch available models from the selected backend (no completion request).
function M.models(provider, callback)
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
    callback(models)
  end
  if provider == 'openrouter' then
    local token = vim.env.OPENROUTER_API_KEY
    if not token or token == '' then return callback(nil, 'Set OPENROUTER_API_KEY to use OpenRouter') end
    get_json('https://openrouter.ai/api/v1/models', { 'Authorization: Bearer ' .. token }, finish)
  elseif provider == 'copilot' then
    copilot_auth(function(token, err)
      if err then return callback(nil, err) end
      get_json('https://api.githubcopilot.com/models', {
        'Authorization: Bearer ' .. token,
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
  end)
end

--- Send an OpenAI-compatible chat completion. callback(message, error).
function M.chat(config, messages, tools, callback)
  local on_result = callback
  callback = function(message, err, usage, detail)
    if err then log_error(config, err, detail) end
    on_result(message, err, usage)
  end
  local function send(url, token, extra_headers)
    local headers = { 'Content-Type: application/json', 'Authorization: Bearer ' .. token }
    vim.list_extend(headers, extra_headers or {})
    local body = { model = config.model, messages = messages }
    if config.provider == 'openrouter' then
      body.usage = { include = true }
      local options = config.options or {}
      if options.preferred_provider and options.preferred_provider ~= '' then
        body.provider = { order = { options.preferred_provider } }
      end
      if options.service_tier and options.service_tier ~= '' then body.service_tier = options.service_tier end
      if options.effort and options.effort ~= '' then body.reasoning = { effort = options.effort } end
    end
    if tools and #tools > 0 then
      body.tools = tools
      body.tool_choice = 'auto'
    end
    request(url, headers, body, function(response, err, detail)
      if err then return callback(nil, err, nil, detail) end
      local choice = response and response.choices and response.choices[1]
      if not choice or not choice.message then
        return callback(nil, 'Response has no assistant message', nil, vim.json.encode(response))
      end
      if config.provider == 'openrouter' then
        local usage = type(response.usage) == 'table' and response.usage or nil
        callback(choice.message, nil, {
          cost = usage and usage.cost,
          prompt_tokens = usage and usage.prompt_tokens,
          completion_tokens = usage and usage.completion_tokens,
          total_tokens = usage and usage.total_tokens,
        })
      else
        callback(choice.message)
      end
    end)
  end

  if config.provider == 'openrouter' then
    local key = vim.env.OPENROUTER_API_KEY
    if not key or key == '' then return callback(nil, 'Set OPENROUTER_API_KEY to use OpenRouter') end
    send('https://openrouter.ai/api/v1/chat/completions', key, {
      'HTTP-Referer: https://github.com/codeit-nvim/codeit.nvim',
      'X-Title: codeit.nvim',
    })
  elseif config.provider == 'copilot' then
    copilot_auth(function(token, err)
      if err then return callback(nil, err) end
      send('https://api.githubcopilot.com/chat/completions', token, {
        'Editor-Version: Neovim/0.12.0',
        'Editor-Plugin-Version: codeit.nvim/0.1.0',
        'Copilot-Integration-Id: vscode-chat',
        'Openai-Intent: conversation-panel',
      })
    end)
  else
    callback(nil, 'Unknown provider: ' .. tostring(config.provider))
  end
end

return M
