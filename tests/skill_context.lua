vim.opt.runtimepath:prepend(vim.fn.getcwd())
local root, temp = vim.fn.getcwd(), vim.fn.tempname()
local workspace = temp .. '/project'
local path = workspace .. '/.agents/skills/review/SKILL.md'
local global_path = vim.fn.expand('~') .. '/.agents/skills/review/SKILL.md'
vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
vim.fn.mkdir(vim.fn.fnamemodify(global_path, ':h'), 'p')
local function write_skill(target, body, manual)
  vim.fn.writefile({ '---', 'description: Review changes',
    'disable-model-invocation: ' .. tostring(manual == true), '---', body }, target)
end
write_skill(path, 'ORIGINAL_SKILL_BODY')
write_skill(global_path, 'GLOBAL_SKILL_BODY', true)
vim.fn.chdir(workspace)
local history = require('codeit.history')
local approval = require('codeit.approval')
local files = require('codeit.context_files')
local requests, callbacks = {}, {}
package.loaded['codeit.providers'] = { chat = function(_, messages, specs, callback)
  requests[#requests + 1] = { messages = vim.deepcopy(messages), specs = specs }
  callbacks[#callbacks + 1] = callback
end }
local toggle_target, toggled
package.loaded['codeit.context_files_picker'] = { show = function(_, list, toggle)
  for _, entry in ipairs(list()) do
    if entry.path == toggle_target then
      local ok, err = toggle(entry)
      assert(ok, err)
      toggled = true
      return
    end
  end
end }
local plugin = require('codeit')
plugin.setup({ max_context_tokens = false, context_review = false,
  compaction = { manual_keep_turns = 0 }, approval = { trusted_workspaces = { [workspace] = 'all' } } })
local function toggle(target)
  toggle_target, toggled = target, false
  plugin.context_files()
  assert(toggled, 'skill missing from picker: ' .. target)
end
local function send()
  plugin.send('Continue the task.' .. string.rep(' Additional task details.', 60))
  return #requests
end
local function answer(index)
  callbacks[index]({ role = 'assistant', content = 'Task completed.' })
end
local function text(index)
  local parts = {}
  for _, message in ipairs(requests[index].messages) do
    if type(message.content) == 'string' then parts[#parts + 1] = message.content end
  end
  return table.concat(parts, '\n')
end
local function count(index, needle)
  local _, matches = text(index):gsub(needle, '')
  return matches
end
local function load_skill()
  local index = send()
  callbacks[index]({ role = 'assistant', tool_calls = { { id = 'load-' .. index, type = 'function',
    ['function'] = { name = 'load_skill', arguments = vim.json.encode({ name = 'review' }) } } } })
  assert(#requests == index + 1)
  answer(index + 1)
  return index + 1
end
local loaded = load_skill()
assert(count(loaded, 'ORIGINAL_SKILL_BODY') == 1, 'skill instructions must appear only once')
for _, message in ipairs(requests[loaded].messages) do
  if message.role == 'tool' then assert(not message.content:find('ORIGINAL_SKILL_BODY', 1, true)) end
end
local id = history.list(workspace)[1].id
local chat = history.load(workspace, id)
assert(chat.selected_skills[1].name == 'review' and chat.selected_skills[1].path == path)
for _, message in ipairs(chat.messages) do
  if message.role == 'tool' then assert(not message.content:find('ORIGINAL_SKILL_BODY', 1, true)) end
end
write_skill(path, 'UPDATED_SKILL_BODY')
local updated = send()
assert(count(updated, 'UPDATED_SKILL_BODY') == 1 and count(updated, 'ORIGINAL_SKILL_BODY') == 0)
answer(updated)

-- Upgrade projection must sanitize old tool results even while their skill is active.
chat = history.load(workspace, id)
for _, message in ipairs(chat.messages) do
  if message.role == 'tool' then message.content = 'Skill review (' .. path .. '):\nLEGACY_SKILL_BODY' end
end
assert(history.save(workspace, id, chat))
plugin.resume(id)
local legacy = send()
assert(count(legacy, 'LEGACY_SKILL_BODY') == 0 and count(legacy, 'UPDATED_SKILL_BODY') == 1)
answer(legacy)

local function compact(summary)
  plugin.compact(true)
  local index = #requests
  assert(#requests[index].specs == 0)
  assert(not text(index):find('LEGACY_SKILL_BODY', 1, true))
  assert(not text(index):find('UPDATED_SKILL_BODY', 1, true))
  callbacks[index]({ role = 'assistant', content = summary })
  local saved = history.load(workspace, id)
  assert(saved.context_summary == summary and saved.context_summary_skills[path])
end
compact('SUMMARY_WITH_SKILL_MATERIAL')
plugin.resume(id)
local retained = send()
assert(text(retained):find('SUMMARY_WITH_SKILL_MATERIAL', 1, true))
answer(retained)
toggle(path) -- active -> off
local unloaded = send()
assert(not text(unloaded):find('SUMMARY_WITH_SKILL_MATERIAL', 1, true))
assert(count(unloaded, 'LEGACY_SKILL_BODY') == 0 and count(unloaded, 'UPDATED_SKILL_BODY') == 0)
assert(history.load(workspace, id).context_summary == nil)
assert(#requests[unloaded].messages > #requests[retained].messages, 'invalidating a summary must restore the transcript')
answer(unloaded)
toggle(path) -- off -> on
load_skill()
compact('SUMMARY_BEFORE_EDIT')
write_skill(path, 'EDITED_AGAIN_SKILL_BODY')
local edited = send()
assert(not text(edited):find('SUMMARY_BEFORE_EDIT', 1, true))
assert(count(edited, 'UPDATED_SKILL_BODY') == 0 and count(edited, 'EDITED_AGAIN_SKILL_BODY') == 1)
answer(edited)
compact('SUMMARY_BEFORE_REVOKE')
assert(approval.set_workspace_trust(nil, workspace))
local revoked = send()
assert(not text(revoked):find('SUMMARY_BEFORE_REVOKE', 1, true))
assert(count(revoked, 'EDITED_AGAIN_SKILL_BODY') == 0 and count(revoked, 'LEGACY_SKILL_BODY') == 0)
answer(revoked)
assert(approval.set_workspace_trust('all', workspace))

-- A same-name fallback, including a manual-only one, cannot inherit activation.
assert(vim.uv.fs_unlink(path))
local fallback = send()
assert(count(fallback, 'GLOBAL_SKILL_BODY') == 0)
for _, entry in ipairs(files.entries(workspace, 'all', {}, history.load(workspace, id).selected_skills)) do
  if entry.name == 'review' then assert(entry.path == global_path and entry.state == 'on' and entry.manual_only) end
end
answer(fallback)
toggle(global_path)
local manual = send()
assert(count(manual, 'GLOBAL_SKILL_BODY') == 1)
answer(manual)
write_skill(path, 'WORKSPACE_REPLACEMENT_BODY', true)
local shadowed = send()
assert(count(shadowed, 'GLOBAL_SKILL_BODY') == 0 and count(shadowed, 'WORKSPACE_REPLACEMENT_BODY') == 0)
answer(shadowed)
toggle(path)
local reactivated = send()
assert(count(reactivated, 'WORKSPACE_REPLACEMENT_BODY') == 1)
answer(reactivated)

-- Pre-upgrade names and summaries have no reliable identity/provenance.
chat = history.load(workspace, id)
chat.selected_skills = { 'review' }
chat.context_summary, chat.compacted_until = 'LEGACY_SUMMARY_WITH_SKILL_MATERIAL', #chat.messages
chat.context_summary_skills = nil
assert(history.save(workspace, id, chat))
plugin.resume(id)
local migrated = send()
assert(count(migrated, 'WORKSPACE_REPLACEMENT_BODY') == 0)
assert(not text(migrated):find('LEGACY_SUMMARY_WITH_SKILL_MATERIAL', 1, true))
local saved = history.load(workspace, id)
assert(#saved.selected_skills == 0 and not saved.context_summary and not saved.compacted_until)
answer(migrated)
vim.fn.chdir(root)
vim.fn.delete(temp, 'rf')
print('codeit skill context tests passed')
