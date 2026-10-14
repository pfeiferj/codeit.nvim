vim.opt.runtimepath:prepend(vim.fn.getcwd())
local temp, cwd = vim.fn.tempname(), vim.fn.getcwd()
vim.fn.mkdir(temp .. '/workspace', 'p')
local stdpath = vim.fn.stdpath
vim.fn.stdpath = function(kind) return kind == 'data' and temp .. '/data' or stdpath(kind) end
vim.fn.chdir(temp .. '/workspace')
vim.fn.writefile({ 'example' }, 'sample.txt')
local requests, callbacks = {}, {}
package.loaded['codeit.providers'] = { chat = function(config, messages, specs, callback)
  requests[#requests + 1] = { config = config, messages = vim.deepcopy(messages) }
  callbacks[#callbacks + 1] = callback
end }
local plugin = require('codeit')
plugin.setup({ context_review = false, max_context_tokens = false })
local approval = require('codeit.tools.approval')
assert(approval.set_workspace_trust('all'))
require('codeit.tools.approval.prompt').show = function() error('unexpected approval prompt') end
local history = require('codeit.chat.storage')
local workspace = history.workspace()
local function reply(message) table.remove(callbacks, 1)(message, nil, { cost = 0, prompt_tokens = 1, completion_tokens = 1 }) end
local function call(id, name, args)
  return { id = id, type = 'function', ['function'] = { name = name, arguments = vim.json.encode(args) } }
end
local function read(id)
  reply({ role = 'assistant', tool_calls = { call(id, 'read_file', { path = 'sample.txt' }) } })
  reply({ role = 'assistant', content = 'Done' })
end
plugin.send('Read sample.txt')
read('first-read')
local origin = history.list(workspace)[1]
assert(#origin.auto_approvals == 1 and origin.auto_approvals[1].tool_call_id == 'first-read')
local json = vim.json.encode(requests[#requests].messages)
assert(not json:find('auto_approvals', 1, true), 'audit metadata must not become model context')
plugin.new()
plugin.send('Another chat')
reply({ role = 'assistant', content = 'No tools' })
local other = history.list(workspace)[1]
assert(other.id ~= origin.id and #other.auto_approvals == 0, 'new chats start with an empty audit')
assert(plugin.resume(origin.id))
plugin.send('Read again')
read('second-read')
assert(#history.load(workspace, origin.id).auto_approvals == 2, 'resume preserves prior records')
plugin.send('Delegate background inspection')
reply({ role = 'assistant', tool_calls = { call('delegate', 'start_subagent', {
  title = 'Inspection', task = 'Read sample.txt', mode = 'background',
}) } })
reply({ role = 'assistant', content = 'Started' })
assert(vim.wait(1000, function() return #callbacks > 0 end))
assert(#history.load(workspace, origin.id).auto_approvals == 3, 'approval-free delegation is recorded')
plugin.new()
plugin.send('An unrelated chat')
-- The pending background provider responds before the new main provider.
reply({ role = 'assistant', tool_calls = { call('agent-read', 'read_file', { path = 'sample.txt' }) } })
reply({ role = 'assistant', content = 'Unrelated answer' })
assert(vim.wait(1000, function() return #callbacks > 0 end))
reply({ role = 'assistant', content = 'Inspection finished' })
local saved = history.load(workspace, origin.id)
assert(#saved.auto_approvals == 4 and saved.auto_approvals[4].tool_call_id == 'agent-read')
assert(saved.auto_approvals[4].subagent_run_id == 1)
local latest = history.list(workspace)[1]
assert(latest.id ~= origin.id and #latest.auto_approvals == 0, 'background audit must not leak into a later chat')
assert(plugin.resume(origin.id))
for _, action in ipairs({ 'archive', 'delete' }) do
  local selected_id = action == 'archive' and origin.id or latest.id
  for _, chat in ipairs(history.list(workspace)) do assert(history.set_summary(workspace, chat.id, 'Saved chat')) end
  local removed = false
  require('codeit.chat.picker').show = function(entries, _, _, delete, archive)
    for _, chat in ipairs(entries) do
      if chat.id == selected_id then
        assert((action == 'archive' and archive or delete)(chat))
        removed = true
      end
    end
  end
  plugin.history()
  assert(removed and history.load(workspace, selected_id) == nil)
  plugin.send('Continue after ' .. action)
  read('after-' .. action)
  latest = history.list(workspace)[1]
  assert(latest.id ~= selected_id and #latest.auto_approvals == 1,
    'continuing removed history must not resurrect or duplicate its audit')
end
local archived_path = temp .. '/data/codeit/archive/' .. vim.fn.sha256(workspace) .. '/' .. origin.id .. '.json'
local archived = vim.json.decode(table.concat(vim.fn.readfile(archived_path), '\n'))
assert(#archived.auto_approvals == 4, 'archive preserves the original audit')
require('codeit.tools.subagents').shutdown()
plugin.close()
vim.fn.chdir(cwd)
vim.fn.delete(temp, 'rf')
print('codeit auto-approval chat lifecycle tests passed')
