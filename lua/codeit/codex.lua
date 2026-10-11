local M = {}
M.url = 'https://chatgpt.com/backend-api/codex'
M.client_version = '0.110.0'

local function nonempty(value)
  return type(value) == 'string' and value ~= '' and not value:find('%c')
end

local function claims(token)
  if type(token) ~= 'string' then return {} end
  local payload = token:match('^[^.]+%.([^.]+)%.')
  if not payload then return {} end
  payload = payload:gsub('-', '+'):gsub('_', '/')
  payload = payload .. string.rep('=', (4 - #payload % 4) % 4)
  local ok, decoded = pcall(function() return vim.json.decode(vim.base64.decode(payload)) end)
  return ok and type(decoded) == 'table' and decoded or {}
end

--- Read fresh credentials each request so CLI login/refresh changes take effect.
--- Never rotate or overwrite the CLI's shared refresh tokens.
function M.credentials()
  local home = vim.env.CODEX_HOME
  if not home or home == '' then home = vim.fn.expand('~/.codex') end
  local ok, auth = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(home .. '/auth.json'), '\n'))
  end)
  if not ok or type(auth) ~= 'table' then
    return nil, 'Codex requires a file-backed ChatGPT login: run `codex login` (auth.json in CODEX_HOME or ~/.codex)'
  end
  local tokens = type(auth.tokens) == 'table' and auth.tokens or {}
  if (auth.auth_mode ~= nil and auth.auth_mode ~= vim.NIL and auth.auth_mode ~= 'chatgpt')
    or not nonempty(tokens.access_token) then
    return nil, 'Codex requires a ChatGPT login, not an API key: run `codex login`'
  end
  local access_claims = claims(tokens.access_token)
  local account = tokens.account_id
  if not nonempty(account) then
    local id_claims = claims(tokens.id_token)
    local info = id_claims['https://api.openai.com/auth'] or access_claims['https://api.openai.com/auth']
    account = type(info) == 'table' and info.chatgpt_account_id or nil
  end
  if not nonempty(account) then return nil, 'Codex login has no account ID: run `codex login` again' end
  if type(access_claims.exp) == 'number' and access_claims.exp <= os.time() + 30 then
    return nil, 'Codex login has expired: refresh your login with `codex login` and retry'
  end
  return { token = tokens.access_token, account_id = account,
    secrets = { tokens.access_token, tokens.id_token, tokens.refresh_token } }
end

function M.headers(auth)
  return {
    'ChatGPT-Account-Id: ' .. auth.account_id,
    'OpenAI-Beta: responses=experimental',
    'originator: codeit.nvim',
    'version: ' .. M.client_version,
    'User-Agent: codeit.nvim/0.1.0',
  }
end

function M.redact(value, auth)
  if type(value) ~= 'string' then return value end
  for _, secret in pairs(auth.secrets) do
    if type(secret) == 'string' and secret ~= '' then value = value:gsub(vim.pesc(secret), '[redacted]') end
  end
  if value:match('^HTTP 401:') then
    value = 'Codex login was rejected (HTTP 401): run `codex login` again and retry'
  end
  return value
end

return M
