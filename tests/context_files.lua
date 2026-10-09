vim.opt.runtimepath:prepend(vim.fn.getcwd())
local root = vim.fn.getcwd()
local temp = vim.fn.tempname()
local home = vim.fn.expand('~')
local workspace = temp .. '/project'
vim.fn.mkdir(workspace .. '/src/inner', 'p')
vim.fn.mkdir(workspace .. '/.agents/skills/review', 'p')
vim.fn.mkdir(home .. '/.claude/skills/global', 'p')
vim.fn.mkdir(home .. '/.config/codeit', 'p')
vim.fn.writefile({ 'global claude' }, home .. '/.claude/CLAUDE.md')
vim.fn.writefile({ 'global config' }, home .. '/.config/codeit/AGENTS.md')
vim.fn.writefile({ 'global skill' }, home .. '/.claude/skills/global/SKILL.md')
vim.fn.writefile({ 'root instruction' }, workspace .. '/AGENTS.md')
vim.fn.writefile({ 'nested instruction' }, workspace .. '/src/CLAUDE.md')
vim.fn.writefile({ 'deep instruction' }, workspace .. '/src/inner/AGENTS.md')
vim.fn.writefile({ '---', 'name: review', 'description: Check changes carefully', '---', 'review secret' },
  workspace .. '/.agents/skills/review/SKILL.md')
vim.fn.writefile({ 'source' }, workspace .. '/src/inner/main.lua')
vim.fn.system({ 'git', '-C', workspace, 'init', '-q' })
vim.fn.system({ 'git', '-C', workspace, 'add', 'AGENTS.md', 'src/CLAUDE.md', 'src/inner/AGENTS.md',
  '.agents/skills/review/SKILL.md', 'src/inner/main.lua' })
vim.fn.chdir(workspace)
local history = require('codeit.history')
local approval = require('codeit.approval')
local files = require('codeit.context_files')
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
assert(content:find('root instruction', 1, true))
assert(not content:find('nested instruction', 1, true))
assert(content:find('Check changes carefully', 1, true))
assert(not content:find('review secret', 1, true))
local nested = text(files.messages(history.workspace(), 'tracked', { 'src/inner/main.lua' }))
assert(nested:find('nested instruction', 1, true) and nested:find('deep instruction', 1, true))
assert(nested:find('global claude', 1, true) < nested:find('root instruction', 1, true))
assert(text(files.messages(history.workspace(), 'tracked', {}, { 'review' })):find('review secret', 1, true))
local skill = files.skill('review', history.workspace(), 'tracked')
assert(skill and skill.content:find('review secret', 1, true))
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
assert(require('codeit.slash_commands').parse('/contextFiles').command == 'CodeitContextFiles')
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
plugin.send('start')
assert(toolsets[1].load_skill and not toolsets[1].read_buffer and not toolsets[1].replace_buffer_lines)
assert(text(requests[1]):find('root instruction', 1, true))
assert(not text(requests[1]):find('nested instruction', 1, true))
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
assert(not text(files.messages(workspace, 'tracked', {}, { 'review' })):find('review secret', 1, true))
plugin.context_full()
local disabled_view = vim.fn.bufnr('codeit://context-full')
assert(not table.concat(vim.api.nvim_buf_get_lines(disabled_view, 0, -1, false), '\n')
  :find('review secret', 1, true))
vim.cmd('close')
assert(toggle_path(skill.path):find('[on]', 1, true))
local id = history.list(workspace)[1].id
plugin.new()
plugin.resume(id)
plugin.send('continued')
assert(text(requests[6]):find('nested instruction', 1, true)
  and text(requests[6]):find('review secret', 1, true))
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
assert(text(files.messages(workspace, 'tracked')):find('updated root instruction', 1, true))
vim.fn.chdir(root)
vim.fn.delete(temp, 'rf')
print('codeit context file tests passed')
