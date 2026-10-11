local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
local temp = vim.fn.tempname()
vim.fn.mkdir(temp .. '/one', 'p')
vim.fn.mkdir(temp .. '/two', 'p')
vim.fn.chdir(temp .. '/one')
local workspace = vim.uv.fs_realpath(vim.fn.getcwd())
local history = require('codeit.chat.storage')

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
  { cost = 0.123456, prompt_tokens = 200, completion_tokens = 10, total_tokens = 210 })
assert(history.load(workspace, first_id).turn_costs[1].cost == 0.123456)
assert(history.load(workspace, first_id).cost_by_function.main_chat.cost == 0.123456)
local first_bucket = history.load(workspace, first_id).cost_by_function.main_chat
assert(first_bucket.tokens_in == 200 and first_bucket.tokens_out == 10)
assert(not first_bucket.missing_in and not first_bucket.missing_out)
assert(vim.deep_equal(first_bucket, history.load(workspace, first_id).turn_costs[1].cost_by_function.main_chat))
plugin.open()
assert(table.concat(vim.api.nvim_buf_get_lines(vim.fn.bufnr('codeit://chat'), 0, -1, false), '\n')
  :find('**You** · Turn cost: $0.123', 1, true))
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
assert(chat.cost == 0.123456 and chat.context_tokens == nil)
assert(#chat.turn_costs == 2 and chat.turn_costs[1].first == 2 and chat.turn_costs[1].cost == 0.123456)
assert(chat.turn_costs[2].first == 4 and chat.turn_costs[2].cost == 0 and chat.turn_costs[2].missing_cost == 1)
assert(chat.cost_by_function.main_chat.requests == 2 and chat.cost_by_function.main_chat.missing_cost == 1)
assert(chat.cost_by_function.main_chat.tokens_in == 200 and chat.cost_by_function.main_chat.tokens_out == 10)
assert(chat.cost_by_function.main_chat.missing_in and chat.cost_by_function.main_chat.missing_out)
assert(not chat.turn_costs[1].cost_by_function.main_chat.missing_in)
assert(chat.turn_costs[2].cost_by_function.main_chat.missing_in)
assert(chat.turn_costs[1].cost_by_function.main_chat.cost == 0.123456)
assert(chat.turn_costs[2].cost_by_function.main_chat.missing_cost == 1)
for _, message in ipairs(requests[#requests].messages) do
  assert(not message.turn_costs and not message.cost_by_function, 'cost metadata must stay out of provider messages')
end

-- Legacy and malformed turn costs must not become fabricated zero-cost turns.
local legacy = { provider = 'openrouter', model = 'test-model', cost = 1,
  messages = { { role = 'user', content = 'old question' }, { role = 'assistant', content = 'old answer' } } }
assert(history.save(workspace, 'legacy', legacy))
assert(#history.load(workspace, 'legacy').turn_costs == 0)
assert(next(history.load(workspace, 'legacy').cost_by_function) == nil)
plugin.resume('legacy')
assert(table.concat(vim.api.nvim_buf_get_lines(vim.fn.bufnr('codeit://chat'), 0, -1, false), '\n')
  :find('Turn cost: unknown', 1, true))
legacy.turn_costs = { { first = 1, cost = -1 }, { first = 2, cost = 1 }, { first = 99, cost = 1 } }
assert(history.save(workspace, 'legacy', legacy))
assert(#history.load(workspace, 'legacy').turn_costs == 0)
assert(history.delete(workspace, 'legacy'))

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
require('codeit.chat.picker').show = function(items, selected_workspace, callback)
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
responses[#responses]({ role = 'assistant', content = 'Implemented the first request and follow-up.' }, nil,
  { cost = 0.05, prompt_tokens = 50, completion_tokens = 5 })
local summarized_chat = history.load(workspace, first_id)
assert(summarized_chat.cost_by_function.history_summary.cost == 0.05)
assert(summarized_chat.cost_by_function.history_summary.requests == 1)
assert(summarized_chat.cost_by_function.history_summary.tokens_in == 50)
assert(summarized_chat.cost_by_function.history_summary.tokens_out == 5)
assert(not summarized_chat.cost_by_function.history_summary.missing_in)
assert(math.abs(summarized_chat.cost - 0.173456) < 0.000000001)
assert(summarized_chat.turn_costs[1].cost == 0.123456 and not summarized_chat.turn_costs[1].cost_by_function.history_summary,
  'history summaries belong to their source chat, not to the active chat or its turns')
assert(not history.load(workspace, second_id).cost_by_function.history_summary)
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
responses[#responses]({ role = 'assistant', content = 'Implemented the first request and the new follow-up.' }, nil,
  { cost = 0.02, prompt_tokens = 20, completion_tokens = 5 })
assert(math.abs(history.load(workspace, first_id).cost_by_function.history_summary.cost - 0.07) < 0.000000001)
assert(history.load(workspace, first_id).cost_by_function.history_summary.requests == 2)
assert(history.load(workspace, first_id).cost_by_function.history_summary.tokens_in == 70)
assert(history.load(workspace, first_id).cost_by_function.history_summary.tokens_out == 10)
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
local before_summary_cost = history.load(workspace, first_id).cost
stale_summary({ role = 'assistant', content = 'Outdated summary.' }, nil, { cost = 0.03 })
assert(math.abs(history.load(workspace, first_id).cost - before_summary_cost - 0.03) < 0.000000001,
  'an obsolete summary still incurs a charge on its original chat')
assert(not history.load(workspace, first_id).turn_costs[#history.load(workspace, first_id).turn_costs].cost_by_function.history_summary)
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

-- Preset changes must not share an in-flight summary request to a different model.
assert(history.save(workspace, 'old-copilot', old_copilot, { clear_summary = true }))
local values = plugin.get_settings()
values.model_presets.fast = { model = 'summary-one' }
assert(plugin.configure(values))
local before_preset = #requests
plugin.history()
assert(requests[#requests].config.model == 'summary-one')
local first_preset = responses[#responses]
values.model_presets.fast.model = 'summary-two'
assert(plugin.configure(values))
plugin.history()
assert(#requests == before_preset + 2 and requests[#requests].config.model == 'summary-two')
first_preset({ role = 'assistant', content = 'Completed the old Copilot task.' })
responses[#responses]({ role = 'assistant', content = 'Completed the old Copilot task.' })
assert(history.load(workspace, 'old-copilot').model_presets == nil,
  'history summaries must not overwrite saved presets')

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

-- Delete only the selected workspace's file; active chats detach from their old ID.
local delete_workspace = temp .. '/delete'
local delete_chat = { provider = 'openrouter', model = 'test', messages = {}, summary = 'Saved chat.' }
assert(history.save(workspace, 'delete-me', delete_chat))
assert(history.save(delete_workspace, 'delete-me', delete_chat))
assert(not history.delete(workspace, '../escape'))
assert(history.delete(workspace, 'delete-me'))
assert(not history.load(workspace, 'delete-me') and history.load(delete_workspace, 'delete-me'))
assert(not history.delete(workspace, 'delete-me'), 'missing files should report a deletion failure')

plugin.new()
plugin.send('chat to delete')
responses[#responses]({ role = 'assistant', content = 'saved answer' })
local active_id = history.list(workspace)[1].id
local delete_active
require('codeit.chat.picker').show = function(items, _, _, delete)
  for _, item in ipairs(items) do
    if item.id == active_id then delete_active = function() return delete(item) end end
  end
end
for _, item in ipairs(history.list(workspace)) do
  assert(history.set_summary(workspace, item.id, 'Saved chat.'))
end
plugin.history()
assert(delete_active)
plugin.send('pending answer')
local ok, err = delete_active()
assert(not ok and err:find('current response', 1, true) and history.load(workspace, active_id))
responses[#responses]({ role = 'assistant', content = 'finished answer' })
assert(delete_active() and not history.load(workspace, active_id))
plugin.send('continue as a new chat')
assert(not history.load(workspace, active_id), 'continued chats must not recreate deleted IDs')
local continued = history.list(workspace)[1]
assert(continued.id ~= active_id and continued.messages[2].content == 'chat to delete')
responses[#responses]({ role = 'assistant', content = 'new answer' })

-- Archives are unchanged files outside every history reader's search path.
local archive_workspace = temp .. '/archive'
local archive_dir = vim.fn.stdpath('data') .. '/codeit/archive/' .. vim.fn.sha256(archive_workspace)
local source = vim.fn.stdpath('data') .. '/codeit/chats/' .. vim.fn.sha256(archive_workspace) .. '/archive-me.json'
local destination = archive_dir .. '/archive-me.json'
assert(history.save(archive_workspace, 'archive-me', delete_chat))
assert(history.save(delete_workspace, 'archive-me', delete_chat))
local original = vim.fn.readfile(source, 'b')
assert(not history.archive(archive_workspace, '../escape'))
assert(history.archive(archive_workspace, 'archive-me'))
assert(vim.deep_equal(vim.fn.readfile(destination, 'b'), original), 'archiving must preserve the entire saved file')
assert(vim.fn.getfperm(archive_dir) == 'rwx------' and vim.fn.getfperm(destination) == 'rw-------')
assert(not history.load(archive_workspace, 'archive-me') and #history.list(archive_workspace) == 0)
assert(history.load(delete_workspace, 'archive-me'), 'archiving must affect only the selected workspace')
for _, item in ipairs(history.list_all()) do
  assert(item.workspace ~= archive_workspace, 'all-workspace tools must not discover archived chats')
end
assert(not history.archive(archive_workspace, 'missing'), 'missing files should report an archive failure')
assert(history.save(archive_workspace, 'archive-me', delete_chat))
local archived, archive_err = history.archive(archive_workspace, 'archive-me')
assert(not archived and archive_err == 'archived chat already exists', 'never overwrite an existing archive')
assert(history.load(archive_workspace, 'archive-me') and vim.deep_equal(vim.fn.readfile(destination, 'b'), original))

-- A failed move must leave the original file available.
assert(history.save(archive_workspace, 'move-failure', delete_chat))
local rename = vim.uv.fs_rename
vim.uv.fs_rename = function() return nil, 'test rename failure' end
archived, archive_err = history.archive(archive_workspace, 'move-failure')
vim.uv.fs_rename = rename
assert(not archived and archive_err == 'test rename failure' and history.load(archive_workspace, 'move-failure'))
assert(vim.fn.filereadable(archive_dir .. '/move-failure.json') == 0)

-- Archiving an active chat detaches it and prevents in-flight responses from recreating it.
active_id = continued.id
local archive_active
require('codeit.chat.picker').show = function(items, _, _, _, archive)
  for _, item in ipairs(items) do
    if item.id == active_id then archive_active = function() return archive(item) end end
  end
end
for _, item in ipairs(history.list(workspace)) do
  assert(history.set_summary(workspace, item.id, 'Saved chat.'))
end
plugin.history()
assert(archive_active)
plugin.send('pending archived answer')
ok, err = archive_active()
assert(not ok and err:find('archiving', 1, true) and history.load(workspace, active_id))
responses[#responses]({ role = 'assistant', content = 'answer before archive' })
assert(archive_active() and not history.load(workspace, active_id))
assert(vim.fn.filereadable(vim.fn.stdpath('data') .. '/codeit/archive/' .. vim.fn.sha256(workspace) .. '/' .. active_id .. '.json') == 1)
plugin.send('continue after archive')
assert(not history.load(workspace, active_id), 'continued chats must not recreate archived IDs')
continued = history.list(workspace)[1]
assert(continued.id ~= active_id and continued.messages[2].content == 'chat to delete')
responses[#responses]({ role = 'assistant', content = 'new answer after archive' })
vim.fn.chdir(temp .. '/two')
ok, err = archive_active()
assert(not ok and err:find('out of date', 1, true), 'stale history views must not archive chats')
vim.fn.chdir(temp .. '/one')

vim.fn.delete(temp, 'rf')
print('codeit history tests passed')
