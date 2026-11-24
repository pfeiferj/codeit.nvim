local M = {}
local persistence = require('codeit.settings.persistence')
local registry = require('codeit.tools.mcp_registry')
local mcp = require('codeit.tools.mcp')

local function map(value) return type(value) == 'table' and value or {} end

function M.read()
  local saved, err = persistence.read_mcp()
  if not saved then vim.notify('codeit: ' .. err, vim.log.levels.WARN) end
  return saved or {}
end

function M.server(id, value)
  if type(value) ~= 'table' or value.headers ~= nil or value.env ~= nil then
    return nil, 'Use environment references for credentials in MCP settings'
  end
  local ok, config = pcall(mcp.configure, { servers = { [id] = value } })
  if not ok then return nil, config end
  return config.servers[id]
end

function M.registry(id, value)
  local ok, config = pcall(registry.configure, { [id] = value })
  if not ok then return nil, config end
  if value == false then return false end
  return config[id]
end

function M.resolve(base, workspace, saved)
  saved = saved or M.read()
  local configured = { servers = vim.deepcopy(base.servers), workspaces = vim.deepcopy(base.workspaces) }
  local sources = {}
  for id in pairs(configured.servers) do sources[id] = 'setup' end
  for id, value in pairs(map(saved.servers)) do
    local server = M.server(id, value)
    if server then configured.servers[id], sources[id] = server, 'settings' end
  end
  configured = registry.merge(configured, workspace)
  for id, server in pairs(configured.servers) do
    sources[id] = sources[id] or 'registry'
    local enabled = map(saved.enabled)[id]
    if type(enabled) == 'boolean' then server.enabled = enabled end
  end
  local overrides = vim.tbl_extend('force', {}, configured.workspaces[workspace] or {})
  for id, enabled in pairs(map(map(saved.workspaces)[workspace])) do
    if type(enabled) == 'boolean' then overrides[id] = enabled end
  end
  configured.workspaces[workspace] = overrides
  return configured, sources
end

function M.registries(base, saved)
  saved = saved or M.read()
  local result = vim.deepcopy(base)
  for id, value in pairs(map(saved.registries)) do
    local normalized = M.registry(id, value)
    if normalized == false then result[id] = nil
    elseif normalized then result[id] = normalized end
  end
  return result
end

function M.set(section, id, value, workspace)
  return persistence.update_mcp(function(saved)
    saved[section] = map(saved[section])
    if section == 'workspaces' then
      local overrides = map(saved.workspaces[workspace])
      overrides[id] = value
      saved.workspaces[workspace] = next(overrides) and overrides or nil
    else
      saved[section][id] = value
      if section == 'servers' and value == nil then
        if type(saved.enabled) == 'table' then saved.enabled[id] = nil end
        for _, overrides in pairs(map(saved.workspaces)) do
          if type(overrides) == 'table' then overrides[id] = nil end
        end
      end
    end
    return saved
  end)
end

return M
