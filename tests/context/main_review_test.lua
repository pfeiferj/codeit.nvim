vim.opt.runtimepath:prepend(vim.fn.getcwd())
local root, temp = vim.fn.getcwd(), vim.fn.tempname()
vim.fn.mkdir(temp, 'p')
vim.fn.chdir(temp)
local main = require('codeit.context.main_review')
local review = require('codeit.context.review')
local tools = require('codeit.tools')
local function call(id, name, keep)
  return { id = id, type = 'function', ['function'] = { name = name,
    arguments = vim.json.encode({ summary = 'Inspect workspace state', keep_in_context = keep }) } }
end
local original_specs = vim.deepcopy(tools.specs)
local specs = main.specs(tools.specs)
for _, spec in ipairs(specs) do
  local fn = spec['function']
  local protected = fn.name == 'ask_user' or fn.name == 'load_skill'
  assert((fn.parameters.properties.keep_in_context ~= nil) == not protected)
  assert(vim.tbl_contains(fn.parameters.required or {}, 'keep_in_context') == not protected)
end
assert(vim.deep_equal(tools.specs, original_specs), 'request schemas must not mutate global tool definitions')
local turn = {
  { role = 'user', content = 'Inspect' },
  { role = 'assistant', content = 'Inspecting.', tool_calls = {
    call('remove', 'git_status', false), call('keep', 'git_diff', true),
    call('missing', 'list_buffers'), call('invalid', 'list_buffers', 'false'),
    call('ask', 'ask_user', false), call('skill', 'load_skill', false),
  } },
}
for _, id in ipairs({ 'remove', 'keep', 'missing', 'invalid', 'ask', 'skill' }) do
  turn[#turn + 1] = { role = 'tool', tool_call_id = id, content = 'result' }
end
turn[#turn + 1] = { role = 'assistant', content = 'Done.' }
local replacements = assert(main.replacements(turn))
assert(#replacements == 1 and replacements[1].tool_call_id == 'remove' and replacements[1].remove == true)
local projected = review.project(turn, { { first = 1, last = #turn, replacements = replacements } })
assert(projected[2].content == 'Inspecting.' and #projected[2].tool_calls == 5)
assert(projected[3].tool_call_id == 'keep')
assert(#assert(main.replacements({ turn[1], turn[2] })) == 0, 'unfinished exchanges must stay')
local malformed = vim.deepcopy(turn)
malformed[2].tool_calls[1]['function'].arguments = 'bad JSON'
assert(#assert(main.replacements(malformed)) == 0)

local requests, executed = {}, {}
package.loaded['codeit.providers'] = {
  chat = function(config, messages, definitions, callback)
    requests[#requests + 1] = { config = config, messages = vim.deepcopy(messages), specs = definitions, callback = callback }
  end,
}
require('codeit.tools.approval').prefetch = function() return nil end
tools.execute = function(name, args, _, callback)
  assert(args.keep_in_context == nil, 'retention metadata must not reach tool execution or validation')
  assert(not tools.validate(name, args))
  executed[#executed + 1] = name
  callback('result: ' .. name)
end
local plugin = require('codeit')
plugin.setup({ system_prompt = 'system', max_context_tokens = false, context_review = 'main',
  context_review_min_tokens = 1000000, approval = { tool_call_risk = 'disabled' } })
local history = require('codeit.chat.storage')
local workspace = history.workspace()
local function latest() return requests[#requests] end
local function has_call(messages, id)
  for _, message in ipairs(messages) do
    for _, item in ipairs(message.tool_calls or {}) do if item.id == id then return true end end
  end
  return false
end
plugin.send('Inspect the workspace')
local id = history.list(workspace)[1].id
for _, spec in ipairs(latest().specs) do
  if spec['function'].name == 'git_status' then
    assert(spec['function'].parameters.properties.keep_in_context.type == 'boolean')
  end
end
latest().callback({ content = 'Checking.', tool_calls = {
  call('remove', 'git_status', false), call('keep', 'git_diff', true), call('missing', 'list_buffers'),
} })
assert(#executed == 3 and #requests == 2)
assert(has_call(latest().messages, 'remove'), 'marked calls must remain during the active turn')
assert(#history.load(workspace, id).context_reviews == 0)
-- A second tool round still sees the first round's marked exchange. Remove an
-- entire tool-only assistant batch as well as one call from the mixed batch.
latest().callback({ content = vim.NIL, tool_calls = { call('second', 'git_status', false) } })
assert(#requests == 3 and has_call(latest().messages, 'remove') and has_call(latest().messages, 'second'))
latest().callback({ content = 'Finished.' })
vim.wait(30, function() return false end, 10)
assert(#requests == 3, 'main retention must not make a background review request')
local saved = history.load(workspace, id)
assert(#saved.context_reviews == 1 and #saved.context_reviews[1].replacements == 2,
  'explicit removals must apply even below the background token threshold')
assert(saved.messages[3].tool_calls[1].id == 'remove' and saved.messages[4].content == 'result: git_status',
  'the saved visible transcript must remain intact')
assert(not saved.cost_by_function.context_review)
plugin.send('Follow up')
assert(not has_call(latest().messages, 'remove') and not has_call(latest().messages, 'second'))
assert(has_call(latest().messages, 'keep') and has_call(latest().messages, 'missing'))
for _, message in ipairs(latest().messages) do
  assert(message.tool_call_id ~= 'remove' and message.tool_call_id ~= 'second', 'remove matching results too')
end
latest().callback({ content = 'Follow-up complete.' })
plugin.resume(id)
plugin.send('After resume')
assert(not has_call(latest().messages, 'remove') and has_call(latest().messages, 'keep'))
latest().callback({ content = 'Resumed.' })
-- No false decisions means no persisted review, and disabled mode must not
-- advertise the retention field or interpret it as a removal decision.
plugin.new()
plugin.send('Keep everything')
latest().callback({ content = 'Checking.', tool_calls = { call('retained', 'git_status', true) } })
latest().callback({ content = 'Done.' })
local keep_id = history.list(workspace)[1].id
assert(#history.load(workspace, keep_id).context_reviews == 0)
plugin.setup({ system_prompt = 'system', max_context_tokens = false, context_review = false,
  approval = { tool_call_risk = 'disabled' } })
plugin.new()
plugin.send('No review')
for _, spec in ipairs(latest().specs) do assert(spec['function'].parameters.properties.keep_in_context == nil) end
latest().callback({ content = 'Done.' })
plugin.close()
vim.fn.chdir(root)
vim.fn.delete(temp, 'rf')
print('main-model context review tests passed')
