local M = {}

local copilot_token
local copilot_expires = 0

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
        callback(nil, 'Invalid HTTP response')
        return
      end
      local ok, decoded = pcall(vim.json.decode, data)
      if not ok then
        callback(nil, 'Invalid JSON response: ' .. data:sub(1, 300))
      elseif tonumber(status) < 200 or tonumber(status) >= 300 then
        local message = type(decoded) == 'table' and decoded.error
        if type(message) == 'table' then message = message.message end
        callback(nil, 'HTTP ' .. status .. ': ' .. tostring(message or data:sub(1, 300)))
      else
        callback(decoded)
      end
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

--- Send an OpenAI-compatible chat completion. callback(message, error).
function M.chat(config, messages, tools, callback)
  local function send(url, token, extra_headers)
    local headers = { 'Content-Type: application/json', 'Authorization: Bearer ' .. token }
    vim.list_extend(headers, extra_headers or {})
    local body = { model = config.model, messages = messages }
    if config.provider == 'openrouter' then body.usage = { include = true } end
    if tools and #tools > 0 then
      body.tools = tools
      body.tool_choice = 'auto'
    end
    request(url, headers, body, function(response, err)
      if err then return callback(nil, err) end
      local choice = response and response.choices and response.choices[1]
      if not choice or not choice.message then
        return callback(nil, 'Response has no assistant message')
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
