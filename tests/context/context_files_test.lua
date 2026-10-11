vim.opt.runtimepath:prepend(vim.fn.getcwd())
local root = vim.fn.getcwd()
local temp = vim.fn.tempname()
local home = vim.fn.expand('~')
local workspace = temp .. '/project'
vim.fn.mkdir(workspace .. '/src/inner', 'p')
vim.fn.mkdir(workspace .. '/.agents/skills/review', 'p')
local global_skills = {
  { name = 'global', path = home .. '/.claude/skills/global/SKILL.md' },
  { name = 'lowercase', path = home .. '/.claude/skills/lowercase/skill.md' },
  { name = 'agents', path = home .. '/.agents/skills/agents/SKILL.md' },
  { name = 'config', path = home .. '/.config/codeit/skills/config/Skill.md' },
}
for _, skill in ipairs(global_skills) do
  vim.fn.mkdir(vim.fn.fnamemodify(skill.path, ':h'), 'p')
  vim.fn.writefile({ '---', 'description: Global ' .. skill.name .. ' description', '---',
    'Global ' .. skill.name .. ' instructions' }, skill.path)
end
vim.fn.mkdir(home .. '/.claude/skills/review', 'p')
vim.fn.writefile({ 'shadowed global review instructions' }, home .. '/.claude/skills/review/SKILL.md')
vim.fn.writefile({ 'global claude' }, home .. '/.claude/CLAUDE.md')
vim.fn.writefile({ 'global config' }, home .. '/.config/codeit/AGENTS.md')
vim.fn.mkdir(temp .. '/outside-skill', 'p')
vim.fn.writefile({ 'escaped global skill instructions' }, temp .. '/outside-skill/SKILL.md')
assert(vim.uv.fs_symlink(temp .. '/outside-skill', home .. '/.agents/skills/escape'))
vim.fn.writefile({ 'root instruction' }, workspace .. '/AGENTS.md')
vim.fn.writefile({ 'nested instruction' }, workspace .. '/src/CLAUDE.md')
vim.fn.writefile({ 'deep instruction' }, workspace .. '/src/inner/AGENTS.md')
vim.fn.writefile({ '---', 'name: review', 'description: "Check changes carefully" # advertised description', '---', 'review secret' },
  workspace .. '/.agents/skills/review/SKILL.md')
vim.fn.writefile({ 'source' }, workspace .. '/src/inner/main.lua')
vim.fn.system({ 'git', '-C', workspace, 'init', '-q' })
vim.fn.system({ 'git', '-C', workspace, 'add', 'AGENTS.md', 'src/CLAUDE.md', 'src/inner/AGENTS.md',
  '.agents/skills/review/SKILL.md', 'src/inner/main.lua' })
vim.fn.chdir(workspace)
local history = require('codeit.chat.storage')
local approval = require('codeit.tools.approval')
local files = require('codeit.context.files')
local function text(messages)
  local parts = {}
  for _, message in ipairs(messages) do
    if type(message.content) == 'string' then parts[#parts + 1] = message.content end
  end
  return table.concat(parts, '\n')
end
assert(#files.messages(history.workspace(), nil) == 0)
local content = text(files.messages(history.workspace(), 'tracked'))
assert(content:find('global claude', 1, true) and content:find('global config', 1, true))
for _, skill in ipairs(global_skills) do
  assert(content:find('Global ' .. skill.name .. ' description', 1, true))
  assert(not content:find('Global ' .. skill.name .. ' instructions', 1, true))
  assert(not files.skill(skill.name, history.workspace(), nil))
  for _, mode in ipairs({ 'tracked', 'all' }) do
    local available = files.skill(skill.name, history.workspace(), mode)
    assert(available and available.path == skill.path, 'global skill not discovered: ' .. skill.path)
    assert(text(files.messages(history.workspace(), mode, {}, { { name = skill.name, path = skill.path } }))
      :find('Global ' .. skill.name .. ' instructions', 1, true))
  end
end
assert(not files.skill('escape', history.workspace(), 'all'))
assert(not content:find('shadowed global review instructions', 1, true))
assert(content:find('root instruction', 1, true))
assert(not content:find('nested instruction', 1, true))
assert(content:find('Check changes carefully', 1, true))
assert(not content:find('review secret', 1, true))
local nested = text(files.messages(history.workspace(), 'tracked', { 'src/inner/main.lua' }))
assert(nested:find('nested instruction', 1, true) and nested:find('deep instruction', 1, true))
assert(nested:find('global claude', 1, true) < nested:find('root instruction', 1, true))
assert(text(files.messages(history.workspace(), 'tracked', {}, { { name = 'review', path = workspace .. '/.agents/skills/review/SKILL.md' } })):find('review secret', 1, true))
local skill = files.skill('review', history.workspace(), 'tracked')
assert(skill and skill.path == workspace .. '/.agents/skills/review/SKILL.md'
  and skill.content:find('review secret', 1, true))
for _, case in ipairs({
  { { 'description: >-', '  Check changes', '  carefully' }, 'Check changes carefully' },
  { { 'description: |-', '  Check changes', '  carefully' }, 'Check changes\ncarefully' },
  { { 'description: "unterminated' }, 'review' },
  { { 'description: # empty' }, 'review' },
}) do
  local lines = { '---' }
  vim.list_extend(lines, case[1])
  vim.list_extend(lines, { '---', 'review secret' })
  vim.fn.writefile(lines, skill.path)
  assert(files.skill('review', workspace, 'tracked').description == case[2])
  assert(text(files.messages(workspace, 'tracked')):find('review: ' .. case[2], 1, true))
end
vim.fn.writefile(vim.split(skill.content, '\n', { plain = true }), skill.path)
vim.fn.writefile({ 'untracked secret' }, workspace .. '/src/inner/CLAUDE.md')
assert(not text(files.messages(history.workspace(), 'tracked', { 'src/inner/main.lua' })):find('untracked secret', 1, true))
assert(text(files.messages(history.workspace(), 'all', { 'src/inner/main.lua' })):find('untracked secret', 1, true))
vim.uv.fs_symlink(home .. '/.claude/CLAUDE.md', workspace .. '/src/leak.md')
assert(not text(files.messages(history.workspace(), 'all', { 'src/leak.md' })):find('nested instruction', 1, true))
local requests, callbacks, toolsets = {}, {}, {}
package.loaded['codeit.providers'] = { chat = function(_, messages, specs, callback)
  requests[#requests + 1] = vim.deepcopy(messages)
  local names = {}
  for _, spec in ipairs(specs) do names[spec['function'].name] = true end
  toolsets[#requests] = names
  callbacks[#callbacks + 1] = callback
end }
local plugin = require('codeit')
plugin.setup({ max_context_tokens = false, approval = { trusted_workspaces = { [workspace] = 'tracked' } } })
assert(vim.fn.exists(':CodeitContextFiles') == 2)
assert(require('codeit.commands.slash').parse('/contextFiles').command == 'CodeitContextFiles')
local function toggle_path(path)
  plugin.context_files()
  local buf = vim.fn.bufnr('codeit://context-files')
  local win = vim.fn.bufwinid(buf)
  assert(win ~= -1)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local row
  for i, line in ipairs(lines) do if line:find(path, 1, true) then row = i; break end end
  assert(row, 'file missing from picker: ' .. path)
  vim.api.nvim_win_set_cursor(win, { row, 0 })
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
    if map.lhs == '<CR>' then map.callback(); break end
  end
  local updated = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
  vim.api.nvim_win_close(win, true)
  return updated
end
assert(toggle_path(workspace .. '/AGENTS.md'):find('[off]', 1, true))
assert(not text(files.messages(workspace, 'tracked')):find('root instruction', 1, true))
assert(toggle_path(workspace .. '/AGENTS.md'):find('[on]', 1, true))
for _, global in ipairs(global_skills) do
  assert(toggle_path(global.path):find('[active]', 1, true))
  assert(toggle_path(global.path):find('[off]', 1, true))
  assert(not files.skill(global.name, workspace, 'tracked'))
  local disabled = text(files.messages(workspace, 'tracked', {}, { { name = global.name, path = global.path } }))
  assert(not disabled:find('Global ' .. global.name .. ' description', 1, true))
  assert(not disabled:find('Global ' .. global.name .. ' instructions', 1, true))
  assert(toggle_path(global.path):find('[on]', 1, true))
  assert(files.skill(global.name, workspace, 'tracked'))
  local advertised = text(files.messages(workspace, 'tracked'))
  assert(advertised:find('Global ' .. global.name .. ' description', 1, true))
  assert(not advertised:find('Global ' .. global.name .. ' instructions', 1, true))
  assert(toggle_path(global.path):find('[active]', 1, true))
end
plugin.send('start')
assert(toolsets[1].load_skill and not toolsets[1].read_buffer and not toolsets[1].replace_buffer_lines)
assert(text(requests[1]):find('root instruction', 1, true))
assert(not text(requests[1]):find('nested instruction', 1, true))
for _, global in ipairs(global_skills) do
  assert(text(requests[1]):find('Global ' .. global.name .. ' instructions', 1, true))
end
callbacks[1]({ role = 'assistant', content = 'ok' })
plugin.send('read nested file')
callbacks[2]({ role = 'assistant', tool_calls = { { id = 'read', type = 'function',
  ['function'] = { name = 'read_file', arguments = vim.json.encode({ path = 'src/inner/main.lua' }) } } } })
assert(#requests == 3)
assert(text(requests[3]):find('nested instruction', 1, true))
callbacks[3]({ role = 'assistant', content = 'done' })
plugin.send('use skill')
callbacks[4]({ role = 'assistant', tool_calls = { { id = 'skill', type = 'function',
  ['function'] = { name = 'load_skill', arguments = vim.json.encode({ name = 'review' }) } } } })
assert(#requests == 5)
assert(text(requests[5]):find('review secret', 1, true))
callbacks[5]({ role = 'assistant', content = 'done' })
assert(toggle_path(skill.path):find('[off]', 1, true))
assert(not files.skill('review', workspace, 'tracked'))
assert(not text(files.messages(workspace, 'tracked', {}, { { name = 'review', path = skill.path } })):find('review secret', 1, true))
plugin.context_full()
local disabled_view = vim.fn.bufnr('codeit://context-full')
local off_context = table.concat(vim.api.nvim_buf_get_lines(disabled_view, 0, -1, false), '\n')
assert(not off_context:find('review secret', 1, true))
assert(not off_context:find('Check changes carefully', 1, true))
assert(not off_context:find('Active skill review', 1, true))
local off_messages = vim.json.decode(off_context)
for _, message in ipairs(off_messages) do
  for _, call in ipairs(message.tool_calls or {}) do
    if call['function'].name == 'load_skill' then assert(call['function'].arguments == '{}') end
  end
end
vim.cmd('close')
assert(toggle_path(skill.path):find('[on]', 1, true))
plugin.context_full()
local on_view = vim.fn.bufnr('codeit://context-full')
local on_context = table.concat(vim.api.nvim_buf_get_lines(on_view, 0, -1, false), '\n')
assert(on_context:find('Check changes carefully', 1, true))
assert(not on_context:find('review secret', 1, true), 'on must unload previous skill results')
vim.cmd('close')
assert(toggle_path(skill.path):find('[active]', 1, true))
for _, global in ipairs(global_skills) do
  assert(toggle_path(global.path):find('[off]', 1, true))
end
assert(toggle_path(global_skills[1].path):find('[on]', 1, true))
local id = history.list(workspace)[1].id
plugin.new()
plugin.resume(id)
plugin.send('continued')
assert(text(requests[6]):find('nested instruction', 1, true)
  and text(requests[6]):find('review secret', 1, true))
for index, global in ipairs(global_skills) do
  assert((files.skill(global.name, workspace, 'tracked') ~= nil) == (index == 1))
  assert(not text(requests[6]):find('Global ' .. global.name .. ' instructions', 1, true))
  assert((text(requests[6]):find('Global ' .. global.name .. ' description', 1, true) ~= nil) == (index == 1))
end
vim.fn.writefile({ 'updated root instruction' }, workspace .. '/AGENTS.md')
plugin.context_full()
local context_buf = vim.fn.bufnr('codeit://context-full')
assert(table.concat(vim.api.nvim_buf_get_lines(context_buf, 0, -1, false), '\n')
  :find('updated root instruction', 1, true))
vim.cmd('close')
assert(approval.set_workspace_trust(nil, workspace))
callbacks[6]({ role = 'assistant', content = 'done' })
plugin.send('after revoke')
assert(not toolsets[7].load_skill, 'untrusted requests must not advertise skill loading')
local system_messages = {}
for _, message in ipairs(requests[7]) do
  if message.role == 'system' then system_messages[#system_messages + 1] = message end
end
assert(not text(system_messages):find('updated root instruction', 1, true))
assert(not text(system_messages):find('review secret', 1, true))
callbacks[7]({ role = 'assistant', content = 'done' })
assert(approval.set_workspace_trust('tracked', workspace))
assert(toggle_path(workspace .. '/AGENTS.md'):find('[off]', 1, true))
plugin.resume(id)
assert(not text(files.messages(workspace, 'tracked')):find('updated root instruction', 1, true))
plugin.send('disabled root')
assert(toolsets[8].load_skill, 'restoring trust must restore the skill tool')
local headers = {}
for _, message in ipairs(requests[8]) do
  if message.role == 'system' then headers[#headers + 1] = message end
end
assert(not text(headers):find('updated root instruction', 1, true))
plugin.new()
for _, global in ipairs(global_skills) do
  assert(files.skill(global.name, workspace, 'tracked'), 'new chats must reset global skill toggles')
end
assert(text(files.messages(workspace, 'tracked')):find('updated root instruction', 1, true))
local manual_skills = { { name = 'review', path = skill.path } }
vim.list_extend(manual_skills, global_skills)
for _, manual in ipairs(manual_skills) do
  vim.fn.writefile({ '---', 'description: Manual ' .. manual.name,
    'disable-model-invocation: true', '---', 'Manual instructions for ' .. manual.name }, manual.path)
  assert(not files.skill(manual.name, workspace, 'tracked'))
end
local entries = files.entries(workspace, 'tracked')
for _, entry in ipairs(entries) do
  if entry.kind == 'skill' then
    assert(entry.manual_only and entry.available and not entry.included and entry.state == 'on')
  end
end
assert(not text(files.messages(workspace, 'tracked')):find('Available skills', 1, true))
local tools = require('codeit.tools')
for _, spec in ipairs(tools.request_specs(workspace, 'tracked')) do
  assert(spec['function'].name ~= 'load_skill', 'manual-only skills must not advertise load_skill')
end
local request = approval.request
approval.request = function() error('manual-only skill loading must not prompt for approval') end
local rejected
tools.execute('load_skill', { name = 'review' }, vim.api.nvim_get_current_buf(), function(result) rejected = result end)
approval.request = request
assert(rejected and rejected:find('manual-only', 1, true))
local activated = toggle_path(skill.path)
assert(activated:find('[active]', 1, true) and activated:find('(manual-only)', 1, true))
plugin.send('manually selected skill')
assert(not toolsets[9].load_skill)
assert(text(requests[9]):find('Manual instructions for review', 1, true))
assert(not text(requests[9]):find('Available skills', 1, true))
callbacks[9]({ role = 'assistant', content = 'done' })
local manual_chat = history.list(workspace)[1].id
plugin.new()
plugin.resume(manual_chat)
plugin.send('continue manual skill')
assert(text(requests[10]):find('Manual instructions for review', 1, true))
assert(not toolsets[10].load_skill)
callbacks[10]({ role = 'assistant', content = 'done' })
assert(toggle_path(skill.path):find('[off]', 1, true))
assert(not text(files.messages(workspace, 'tracked', {}, { { name = 'review', path = skill.path } })):find('Manual instructions for review', 1, true))
assert(toggle_path(skill.path):find('[on]', 1, true))
assert(not text(files.messages(workspace, 'tracked')):find('Manual review', 1, true))
vim.fn.writefile({ '---', 'description: Normal review', 'disable-model-invocation: false', '---', 'Normal instructions' }, skill.path)
assert(files.skill('review', workspace, 'tracked'))
assert(text(files.messages(workspace, 'tracked')):find('review: Normal review', 1, true))
local has_loader = false
for _, spec in ipairs(tools.request_specs(workspace, 'tracked')) do
  has_loader = has_loader or spec['function'].name == 'load_skill'
end
assert(has_loader, 'an invocable skill must restore load_skill')
approval.request = function() error('manual-only skills must remain blocked when load_skill is advertised') end
rejected = nil
tools.execute('load_skill', { name = global_skills[1].name }, vim.api.nvim_get_current_buf(), function(result) rejected = result end)
approval.request = request
assert(rejected and rejected:find('manual-only', 1, true))
vim.fn.chdir(root)
vim.fn.delete(temp, 'rf')
print('codeit context file tests passed')
