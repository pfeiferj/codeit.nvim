local M = {}
local copilot_token
local copilot_expires = 0

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

function M.token(callback)
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

return M
