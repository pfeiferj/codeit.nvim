local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
local temp = vim.fn.tempname()
vim.fn.mkdir(temp .. '/one', 'p')
vim.fn.mkdir(temp .. '/two', 'p')
vim.fn.chdir(temp .. '/one')
local workspace = vim.uv.fs_realpath(vim.fn.getcwd())
local history = require('codeit.history')

-- Large monotonic clock values must not turn IDs into scientific notation.
do
  local original_hrtime = vim.uv.hrtime
  local id_workspace = temp .. '/ids'
  local saved_chat = { provider = 'openrouter', model = 'test-model', messages = {} }
  local clocks = { 1234567890123, 100000000000000, 123456789012345, 1000000000000000 }
  for _, clock in ipairs(clocks) do
    vim.uv.hrtime = function() return clock end
    local id = history.new_id()
    vim.uv.hrtime = original_hrtime
    assert(id:match('^[0-9]+%-[0-9]+$'), 'generated chat ID must use decimal digits: ' .. id)
    assert(id:match('%-(%d+)$') == string.format('%.0f', clock), 'ID must retain the clock value')
    assert(history.save(id_workspace, id, saved_chat), 'generated chat ID must be saveable')
    assert(history.load(id_workspace, id).id == id, 'generated chat ID must be loadable')
  end
  assert(#history.list(id_workspace) == #clocks, 'generated chat IDs must appear in history')
  for _, id in ipairs({ '', '../escape', '1-1e+14', '1-1.234e14', 'nested/id' }) do
    local ok, err = history.save(id_workspace, id, saved_chat)
    assert(not ok and err == 'invalid chat id', 'unsafe chat IDs must still be rejected')
  end
end

local responses, requests = {}, {}
package.loaded['codeit.providers'] = {
  chat = function(config, messages, _, callback)
    requests[#requests + 1] = { config = vim.deepcopy(config), messages = vim.deepcopy(messages) }
    responses[#responses + 1] = callback
  end,
}
local plugin = require('codeit')
plugin.setup({ provider = 'openrouter' })
plugin.send('first question')
local entries = history.list(workspace)
assert(#entries == 1 and entries[1].messages[2].content == 'first question')
local first_id = entries[1].id
local stored = vim.fn.stdpath('data') .. '/codeit/chats/' .. vim.fn.sha256(workspace) .. '/' .. first_id .. '.json'
assert(vim.fn.getfperm(stored) == 'rw-------')
responses[#responses]({ role = 'assistant', content = 'first answer' }, nil,
  { cost = 0.12, prompt_tokens = 200, completion_tokens = 10, total_tokens = 210 })
assert(history.load(workspace, first_id).messages[3].content == 'first answer')
plugin.new()
plugin.send('second question')
assert(#history.list(workspace) == 2)
local second_id = history.list(workspace)[1].id
plugin.resume(first_id)
plugin.send('follow up')
assert(requests[#requests].messages[3].content == 'first answer')
assert(requests[#requests].messages[4].content == 'follow up')
assert(#history.list(workspace) == 2, 'resuming must not create a duplicate')
assert(history.list(workspace)[1].id == first_id, 'recently updated chat should appear first')
responses[#responses]({ role = 'assistant', content = 'follow up answer' })
local chat = history.load(workspace, first_id)
assert(chat.cost == 0.12 and chat.context_tokens == nil)

-- A pending tool batch must not be replayed to the provider after restart.
plugin.resume(second_id)
plugin.send('use a tool')
responses[#responses]({ role = 'assistant', content = vim.NIL, tool_calls = { {
  id = 'pending', type = 'function', ['function'] = { name = 'read_file', arguments = '{"path":"pending.txt"}' },
} } })
local pending = history.load(workspace, second_id)
assert(pending.messages[#pending.messages].content == 'use a tool')
plugin.new() -- cancel any outstanding tool approval
plugin.resume(second_id)
plugin.send('continue safely')
assert(requests[#requests].messages[#requests[#requests].messages].content == 'continue safely')
for _, message in ipairs(requests[#requests].messages) do
  assert(message.role ~= 'tool' and not message.tool_calls, 'incomplete tool batch should be removed')
end

local selected, selections = nil, 0
require('codeit.history_picker').show = function(items, selected_workspace, callback)
  selections = selections + 1
  assert(#items >= 2 and selected_workspace == workspace)
  local summarized
  for _, item in ipairs(items) do
    if item.id == first_id then summarized = item end
  end
  assert(summarized)
  selected = function() callback(summarized) end
end
local count = #requests
plugin.history()
assert(#requests == count + 1, 'only answered, unsummarized chats need a request')
assert(selections == 0, 'history should wait for summaries before showing the picker')
assert(requests[#requests].config.model == 'openai/gpt-4o-mini')
assert(#requests[#requests].messages == 2 and #requests[#requests].messages[2].content > 0)
plugin.history()
assert(#requests == count + 1, 'concurrent history views must share a summary request')
responses[#responses]({ role = 'assistant', content = 'Implemented the first request and follow-up.' })
assert(selections == 1)
assert(history.load(workspace, first_id).summary == 'Implemented the first request and follow-up.')
plugin.history()
assert(#requests == count + 1 and selections == 2, 'cached summaries must not be requested again')
selected()
assert(requests[#requests].config.provider == 'openrouter')
plugin.send('a new follow up')
assert(history.load(workspace, first_id).summary == nil,
  'sending a new question must clear the cached summary')
plugin.history()
assert(#requests == count + 2, 'unfinished turns must not trigger a summary request')
responses[#responses]({ role = 'assistant', content = 'new answer' })
assert(history.load(workspace, first_id).summary == nil, 'ordinary saves must not restore the old summary')
plugin.history()
assert(#requests == count + 3, 'finished follow-ups need an updated summary')
assert(requests[#requests].messages[2].content:find('a new follow up', 1, true))
responses[#responses]({ role = 'assistant', content = 'Implemented the first request and the new follow-up.' })
assert(history.load(workspace, first_id).summary == 'Implemented the first request and the new follow-up.')
plugin.history()
assert(#requests == count + 3, 'updated summaries are cached until the next question')
plugin.resume(second_id)
plugin.send('finish the second task')
responses[#responses]({ role = 'assistant', content = 'second answer' })
local before_retry = #requests
plugin.history()
assert(#requests == before_retry + 1, 'newly answered chats need a summary')
responses[#responses](nil, 'temporary failure')
assert(history.load(workspace, second_id).summary == nil, 'failed summaries must not be cached')
plugin.history()
assert(#requests == before_retry + 2, 'failed summaries should be retried')
responses[#responses]({ role = 'assistant', content = 'Completed the second task.' })
assert(history.load(workspace, second_id).summary == 'Completed the second task.')

-- An old summary request must not restore a summary after a new question.
plugin.resume(first_id)
plugin.send('third question')
responses[#responses]({ role = 'assistant', content = 'third answer' })
plugin.history()
local stale_summary = responses[#responses]
plugin.send('fourth question')
local fourth_answer = responses[#responses]
assert(history.load(workspace, first_id).summary == nil)
stale_summary({ role = 'assistant', content = 'Outdated summary.' })
assert(history.load(workspace, first_id).summary == nil, 'stale in-flight summaries must be discarded')
fourth_answer({ role = 'assistant', content = 'fourth answer' })
plugin.history()
responses[#responses]({ role = 'assistant', content = 'Current summary.' })
assert(history.load(workspace, first_id).summary == 'Current summary.')

vim.fn.chdir(temp .. '/two')
plugin.new()
assert(#history.list(history.workspace()) == 0)
plugin.send('other workspace')
assert(#history.list(history.workspace()) == 1 and #history.list(workspace) == 2)
assert(not plugin.resume(first_id), 'history must be isolated by workspace')
vim.fn.chdir(temp .. '/one')
plugin.setup({ provider = 'copilot' }) -- simulate a new session with different defaults
local saved_requests = #requests
plugin.history()
assert(#requests == saved_requests, 'saved summaries survive a new session and provider change')
plugin.resume(first_id)
plugin.send('back in first workspace')
assert(history.load(workspace, first_id).summary == nil, 'resuming and sending also invalidates the summary')
assert(requests[#requests].config.provider == 'openrouter')
assert(requests[#requests].config.model == 'openai/gpt-4o-mini')
assert(requests[#requests].messages[3].content == 'first answer')
-- Mixed-provider history uses the active provider/model, not saved chat settings.
local old_copilot = {
  provider = 'copilot', model = 'saved-copilot-model', updated_at = 1,
  messages = {
    { role = 'user', content = 'old Copilot task' },
    { role = 'assistant', content = 'completed Copilot task' },
  },
}
assert(history.save(workspace, 'old-copilot', old_copilot))
plugin.setup({ provider = 'openrouter', models = { openrouter = 'active-openrouter-model' } })
local before_mixed = #requests
plugin.history()
assert(#requests == before_mixed + 1)
assert(requests[#requests].config.provider == 'openrouter', 'old Copilot chats must use active OpenRouter')
assert(requests[#requests].config.model == 'active-openrouter-model', 'summaries must use the active model')
plugin.history()
assert(#requests == before_mixed + 1, 'same-provider history views still share requests')
local openrouter_summary = responses[#responses]

-- Switching providers must not reuse an in-flight request to the previous provider.
plugin.setup({ provider = 'copilot', models = { copilot = 'active-copilot-model' } })
plugin.history()
assert(#requests == before_mixed + 2, 'different active providers need separate summary requests')
assert(requests[#requests].config.provider == 'copilot')
assert(requests[#requests].config.model == 'active-copilot-model')
openrouter_summary({ role = 'assistant', content = 'Completed the old Copilot task.' })
responses[#responses]({ role = 'assistant', content = 'Completed the old Copilot task.' })
local saved_copilot = history.load(workspace, 'old-copilot')
assert(saved_copilot.provider == 'copilot' and saved_copilot.model == 'saved-copilot-model',
  'summarizing must not change the saved provider/model')

local old_openrouter = vim.deepcopy(old_copilot)
old_openrouter.provider, old_openrouter.model = 'openrouter', 'saved-openrouter-model'
assert(history.save(workspace, 'old-openrouter', old_openrouter))
plugin.history()
assert(#requests == before_mixed + 3)
assert(requests[#requests].config.provider == 'copilot', 'old OpenRouter chats must use active Copilot')
assert(requests[#requests].config.model == 'active-copilot-model')
responses[#responses]({ role = 'assistant', content = 'Completed the old OpenRouter task.' })

-- A resumed chat's model override is also the active model for history summaries.
assert(history.save(workspace, 'old-copilot', old_copilot, { clear_summary = true }))
assert(plugin.resume('old-openrouter'))
plugin.history()
assert(requests[#requests].config.provider == 'openrouter')
assert(requests[#requests].config.model == 'saved-openrouter-model')
responses[#responses]({ role = 'assistant', content = 'Completed the old Copilot task.' })

-- Secondary changes must not share an in-flight summary request to a different model.
assert(history.save(workspace, 'old-copilot', old_copilot, { clear_summary = true }))
local values = plugin.get_settings()
values.secondary_models.openrouter = 'secondary-one'
assert(plugin.configure(values))
local before_secondary = #requests
plugin.history()
assert(requests[#requests].config.model == 'secondary-one')
local first_secondary = responses[#responses]
values.secondary_models.openrouter = 'secondary-two'
assert(plugin.configure(values))
plugin.history()
assert(#requests == before_secondary + 2 and requests[#requests].config.model == 'secondary-two')
first_secondary({ role = 'assistant', content = 'Completed the old Copilot task.' })
responses[#responses]({ role = 'assistant', content = 'Completed the old Copilot task.' })
assert(history.load(workspace, 'old-copilot').secondary_models == nil,
  'history summaries must not overwrite saved secondary settings')

-- Older histories still resume, and malformed display data cannot break rendering.
assert(vim.deep_equal(history.load(workspace, 'old-copilot').command_results, {}))
local with_commands = vim.deepcopy(old_copilot)
with_commands.messages[#with_commands.messages + 1] = {
  role = 'assistant', tool_calls = { { id = 'unfinished' } },
}
with_commands.command_results = {
  { command = '/trustStatus', output = 'before the turn', after_message = 0 },
  { command = '/context', output = 'during the unfinished batch', after_message = 3 },
  { command = '/bad', output = 'negative index', after_message = -1 },
  { command = '/bad', output = 'fractional index', after_message = 0.5 },
  { command = '/bad', output = {}, after_message = 1 },
  { command = '/bad', output = 'missing index' },
  'not a result',
}
assert(history.save(workspace, 'with-commands', with_commands))
local restored = history.load(workspace, 'with-commands')
assert(#restored.messages == 2 and #restored.command_results == 2)
assert(restored.command_results[1].after_message == 0)
assert(restored.command_results[2].after_message == 2,
  'results from a removed tool batch should remain at the end of the surviving transcript')
assert(plugin.resume('with-commands'), 'valid command results should resume alongside older chat formats')

vim.fn.delete(temp, 'rf')
print('codeit history tests passed')
