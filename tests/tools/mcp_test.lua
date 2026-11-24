vim.opt.runtimepath:prepend(vim.fn.getcwd())
local mcp = require('codeit.tools.mcp')
local tools = require('codeit.tools')
local approval = require('codeit.tools.approval')
local workspace = require('codeit.chat.storage').workspace()
local fixture = workspace .. '/tests/tools/mcp_fixture.lua'
local server = { command = vim.v.progpath, args = { '--headless', '-u', 'NONE', '-l', fixture },
  description = 'Find documentation', timeout_ms = 1500 }
local off = vim.tbl_extend('force', server, { enabled = false })
local config = mcp.configure({ servers = { demo = off, disabled = server },
  workspaces = { [workspace .. '/.'] = { demo = true, disabled = false } } })
assert(not pcall(mcp.configure, { servers = { demo = server }, workspaces = { [workspace] = { demo = server } } }))
assert(not pcall(mcp.configure, { servers = { demo = { url = 'https://user:token@example.invalid' } } }))

local live, approvals, choice = true, 0, 'once'
local state = mcp.new(config, workspace, function() return live end)
approval.setup({ tool_call_risk = true, trusted_workspaces = { [workspace] = 'all' },
  validators = { function() return 'approve' end } })
require('codeit.tools.approval.prompt').show = function(text, options, cb)
  assert(text:find('External action:', 1, true), text)
  for _, option in ipairs(options) do assert(option.id ~= 'always') end
  approvals = approvals + 1
  cb(choice)
end
require('codeit.ui.input').show = function(_, cb) cb(nil) end

local function execute(name, args, advertised)
  local result
  tools.execute(name, args, nil, function(value) result = value end, function() return live end,
    { mcp_state = state, mcp_advertised = advertised })
  assert(vim.wait(5000, function() return result ~= nil end), name)
  return result
end
local function has(text, expected) assert(text:find(expected, 1, true), text) end
local discovery = mcp.discovery_name
local specs, advertised = mcp.specs(state)
assert(#specs == 1 and next(state.connections) == nil and approvals == 0)
assert(vim.deep_equal(specs[1]['function'].parameters.properties.server.enum, { 'demo' }))
assert(vim.deep_equal(mcp.specs(mcp.new(mcp.configure(), workspace)), {}))
local elsewhere = mcp.specs(mcp.new(config, workspace .. '/elsewhere'))
assert(vim.deep_equal(elsewhere[1]['function'].parameters.properties.server.enum, { 'disabled' }))
has(execute(discovery, { server = 'disabled' }, advertised), 'Error:')
has(execute(discovery, { server = 'demo' }, {}), 'not advertised')
assert(next(state.connections) == nil and approvals == 0)
choice = 'reject'
has(execute(discovery, { server = 'demo' }, advertised), 'Rejected')
assert(next(state.connections) == nil and approvals == 1)
choice = 'once'
local catalog = vim.json.decode(execute(discovery, { server = 'demo' }, advertised))
assert(catalog.tools[1].name == 'other' and catalog.tools[2].name == 'echo.test' and approvals == 2)
assert(#mcp.specs(state) == 1)
has(execute(discovery, { server = 'demo', tool = 'echo.test' }, advertised), 'Activated')
local native, current
specs, current = mcp.specs(state)
assert(#specs == 2 and approvals == 2)
native = specs[2]['function']
assert(native.name:match('^mcp__[%w_-]+$') and #native.name <= 64)
local reviewed = require('codeit.context.main_review').specs(specs)
assert(vim.deep_equal(reviewed[2]['function'].parameters, native.parameters))
assert(native.parameters.additionalProperties == true and native.parameters.required == nil)
has(execute(native.name, {}, advertised), 'not advertised')
local inputs = { keep_in_context = false, safety_score = -2, payload = { sample = '' } }
local result = vim.json.decode(execute(native.name, inputs, current))
assert(vim.deep_equal(result.structuredContent, inputs) and approvals == 3)
assert(vim.json.encode(vim.json.decode(execute(native.name, {}, current)).structuredContent) == '{}')
has(execute(native.name, { fail = true }, current), 'Error: MCP tool returned an error')
has(execute(native.name, { change = true }, current), 'echo')
assert(#mcp.specs(state) == 1)
has(execute(native.name, {}, current), 'no longer available')
has(execute(discovery, { server = 'demo', tool = 'echo.test' }, advertised), 'Activated')
specs, current = mcp.specs(state)
assert(#specs == 2 and specs[2]['function'].name == native.name)
has(execute(native.name, { timeout = true }, current), 'timed out')
assert(#mcp.specs(state) == 1 and state.connections.demo.client.closed)
has(execute(discovery, { server = 'demo', tool = 'echo.test' }, advertised), 'Activated')
local client = state.connections.demo.client
live = false
assert(vim.wait(2000, function() return client.closed end), 'turn end should close the client')

local requests = {}
require('codeit.providers').chat = function(_, messages, definitions, callback)
  local visible = {}
  for _, definition in ipairs(definitions) do visible[definition['function'].name] = definition['function'] end
  requests[#requests + 1] = { messages = vim.deepcopy(messages), visible = visible, callback = callback }
end
local plugin = require('codeit')
plugin.setup({ max_context_tokens = false, context_review = 'main', mcp = { servers = { demo = server } } })
plugin.open()
plugin.send('Use the echo tool')
local function request(index)
  assert(vim.wait(5000, function() return requests[index] ~= nil end), 'expected request ' .. index)
  return requests[index]
end
local function reply(index, name, args)
  request(index).callback({ role = 'assistant', tool_calls = { { id = 'call_' .. index, type = 'function',
    ['function'] = { name = name, arguments = vim.json.encode(args) } } } })
end
assert(request(1).visible[discovery] and not request(1).visible[native.name])
reply(1, discovery, { server = 'demo', tool = 'echo.test' })
assert(vim.deep_equal(request(2).visible[native.name].parameters, native.parameters))
reply(2, native.name, inputs)
local last = request(3).messages[#request(3).messages]
assert(last.role == 'tool' and last.tool_call_id == 'call_2')
assert(vim.deep_equal(vim.json.decode(last.content).structuredContent, inputs))
request(3).callback({ role = 'assistant', content = 'Done' })
plugin.send('Next turn')
assert(request(4).visible[discovery] and not request(4).visible[native.name])
request(4).callback({ role = 'assistant', content = 'Done' })
