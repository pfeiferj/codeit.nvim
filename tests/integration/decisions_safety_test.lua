vim.opt.runtimepath:prepend(vim.fn.getcwd())
local http_requests = {}
package.loaded['codeit.providers.http'] = { post = function(url, _, body, callback, _, active)
  http_requests[#http_requests + 1] = { url = url, body = body, callback = callback, active = active }
end }
vim.env.TYPESAFE_API_KEY = 'test-key'
local providers = require('codeit.providers')
local requests, responses = {}, {}
providers.chat = function(config, messages, specs, callback)
  requests[#requests + 1] = { config = config, messages = vim.deepcopy(messages), specs = specs }
  responses[#responses + 1] = callback
end
local function reply(message) assert(table.remove(responses, 1))(message) end
local call_id = 0
local function call(arguments)
  call_id = call_id + 1
  return { id = 'call' .. call_id, type = 'function', ['function'] = {
    name = 'run_command', arguments = vim.json.encode(arguments),
  } }
end
local function classified(index, score, write, compliant)
  local request = assert(http_requests[index])
  request.callback({ answers = {
    risk_score = { type = 'score', score = score },
    is_write = { type = 'choice', choice = write and 'true' or 'false' },
    rule_compliant = { type = 'choice', choice = compliant and 'true' or 'false' },
  }, usage = { input_tokens = 50, output_tokens = 10 } })
end
local plugin = require('codeit')
plugin.setup({ max_context_tokens = false, context_review = false,
  approval = { tool_call_risk = 'decisions', read_commands = { { argv = { 'inspect' } } } },
})
plugin.open()
local process = require('codeit.process')
local runs = 0
process.run = function(_, _, callback)
  runs = runs + 1
  callback({ code = 0, stdout = 'inspected', stderr = '' })
end
local prompt = require('codeit.tools.approval.prompt')
local choose, text, typed, updates = nil, nil, nil, 0
prompt.show = function(body, _, callback)
  text, choose = body, callback
  return function(body) text = body; updates = updates + 1 end
end
require('codeit.ui.input').show = function(config, callback)
  typed = config.expected
  callback(config.expected)
end
plugin.send('Inspect the project, but do not change files')
assert(#requests == 1)
for _, definition in ipairs(requests[1].specs) do
  local params = definition['function'].parameters
  assert(params.properties.summary and vim.tbl_contains(params.required, 'summary'))
  assert(not params.properties.risk_score and not params.properties.is_write)
end
reply({ role = 'assistant', tool_calls = {
  call({ argv = { 'inspect' }, summary = 'Inspect the project.' }),
  call({ argv = { 'inspect' } }),
  call({ argv = { 'inspect' }, summary = 'Untrusted score.', risk_score = 0 }),
} })
assert(#http_requests == 1 and #requests == 1 and runs == 0)
assert(http_requests[1].url == 'https://api.typesafe.ai/v1/systemone')
local body = http_requests[1].body
assert(body.model == 'jev-latest' and body.questions.risk_score.type == 'score')
assert(body.questions.rule_compliant and body.state.summary == 'Inspect the project.')
assert(body.state.arguments.summary == nil and body.state.arguments.risk_score == nil)
assert(body.state.user_request:find('do not change files', 1, true))
classified(1, 0, false, true)
assert(vim.wait(2000, function() return #requests == 2 end))
assert(runs == 1 and choose == nil)
local messages = requests[2].messages
assert(messages[#messages - 2].content:find('inspected', 1, true))
assert(messages[#messages - 1].content:find('missing argument summary', 1, true))
assert(messages[#messages].content:find('unknown argument risk_score', 1, true))

-- Unmatched calls show the main model's summary while awaiting classification.
reply({ role = 'assistant', tool_calls = { call({ argv = { 'other' }, summary = '**Main summary**' }) } })
assert(vim.wait(2000, function() return choose ~= nil end))
assert(#http_requests == 2 and text:find('Pending', 1, true))
assert(text:find('\\*\\*Main summary\\*\\*', 1, true))
choose('once')
assert(runs == 1 and #requests == 2, 'approval cannot proceed while decisions are pending')
classified(2, 6.1, true, false)
assert(updates > 0 and text:find('8/10', 1, true))
choose('always')
assert(vim.wait(2000, function() return #requests == 3 end))
assert(typed == 'approve run_command' and runs == 2)

-- A low risk score cannot bypass a write classification or a rule-scope failure.
choose, typed = nil, nil
reply({ role = 'assistant', tool_calls = { call({ argv = { 'inspect' }, summary = 'Possible side effects.' }) } })
assert(#http_requests == 3)
classified(3, 0, true, true)
assert(vim.wait(2000, function() return choose ~= nil end))
assert(runs == 2 and text:find('1/10', 1, true) and text:find('Possible side effects.', 1, true))
choose('reject')
assert(vim.wait(2000, function() return #requests == 4 end))
choose = nil
reply({ role = 'assistant', tool_calls = { call({ argv = { 'inspect' }, summary = 'Outside rule scope.' }) } })
classified(4, 0, false, false)
assert(vim.wait(2000, function() return choose ~= nil end))
assert(runs == 2)
choose(nil)
assert(vim.wait(2000, function() return #requests == 5 end))

-- Malformed responses fail closed and preserve the main-model summary.
choose = nil
reply({ role = 'assistant', tool_calls = { call({ argv = { 'inspect' }, summary = 'Summary survives failure.' }) } })
http_requests[5].callback({ answers = { risk_score = { type = 'score', score = 0 } } })
assert(vim.wait(2000, function() return choose ~= nil end))
assert(runs == 2 and text:find('Unavailable', 1, true) and text:find('Summary survives failure.', 1, true))
choose('once')
assert(vim.wait(2000, function() return #requests == 6 end))
assert(typed == 'approve run_command' and runs == 3)

-- Cancelled decisions cannot execute a queued command.
choose = nil
reply({ role = 'assistant', tool_calls = { call({ argv = { 'inspect' }, summary = 'Cancelled inspection.' }) } })
assert(#http_requests == 6)
plugin.stop()
classified(6, 0, false, true)
assert(runs == 3 and #requests == 6 and choose == nil)
print('integration decisions risk tests passed')
