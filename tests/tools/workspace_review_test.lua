vim.opt.runtimepath:prepend(vim.fn.getcwd())
local root = vim.fn.getcwd()
local data = vim.fn.tempname()
vim.env.XDG_DATA_HOME = data
local codeit = require('codeit')
local approval = require('codeit.tools.approval')
local history = require('codeit.chat.storage')
local workspaces = require('codeit.workspaces')
local parent = assert(vim.uv.fs_mkdtemp(vim.uv.os_tmpdir() .. '/codeit-workspace-review-XXXXXX'))
local child, nested, sibling = parent .. '/repo', parent .. '/repo/nested', parent .. '/other'
local old, removed = parent .. '-old', parent .. '-removed'
for _, path in ipairs({ nested, sibling, old, removed }) do vim.fn.mkdir(path, 'p') end
parent = vim.uv.fs_realpath(parent)
child, nested, sibling = parent .. '/repo', parent .. '/repo/nested', parent .. '/other'
local temporary = vim.fn.tempname()
vim.fn.mkdir(temporary .. '/configured', 'p')
codeit.setup({ approval = { trusted_workspaces = {
  [parent] = 'all', [child] = 'tracked', [temporary .. '/configured'] = 'all',
} } })

-- Opening a session without sending/saving a chat still remembers the workspace.
vim.cmd.cd(nested)
codeit.new()
vim.cmd.cd(sibling)
codeit.new()
assert(workspaces.record(removed))
assert(workspaces.record(removed), 'recording a path twice must be harmless')
vim.fn.delete(removed, 'rf')
assert(history.save(old, 'legacy', { provider = 'openrouter', model = 'test', messages = {} }))
assert(approval.set_workspace_trust(nil, child))
local trust_path = vim.fn.stdpath('data') .. '/codeit/trusted_workspaces.json'
local trust_before = table.concat(vim.fn.readfile(trust_path), '\n')

local function entries()
  local result, previous = {}, nil
  for _, entry in ipairs(workspaces.list()) do
    assert(not previous or previous < entry.workspace, 'paths must be sorted and unique')
    previous = entry.workspace
    result[entry.workspace] = entry
  end
  return result
end
-- Temporary paths must be hidden regardless of how they entered the list.
assert(workspaces.record(temporary))
assert(workspaces.record(temporary .. '/one'))
local seen_path = vim.fn.stdpath('data') .. '/codeit/seen_workspaces.json'
local seen = vim.json.decode(table.concat(vim.fn.readfile(seen_path), '\n'))
assert(not seen[temporary] and not seen[temporary .. '/one'], 'temporary visits must not be remembered')
seen[temporary .. '/remembered'] = true
local previous_temporary = '/tmp/nvim.codeit-test/old-session/0/ids'
seen[previous_temporary] = true
vim.fn.writefile({ vim.json.encode(seen) }, seen_path)
assert(history.save(temporary .. '/chat', 'temporary', { provider = 'openrouter', model = 'test', messages = {} }))
assert(approval.set_workspace_trust('all', temporary .. '/trusted'))
local workspace = history.workspace
history.workspace = function() return temporary end
local temporary_rows = entries()
history.workspace = workspace
assert(not temporary_rows[previous_temporary], 'temporary paths from past sessions must stay hidden')
for _, suffix in ipairs({ '', '/one', '/remembered', '/chat', '/trusted', '/configured' }) do
  assert(not temporary_rows[temporary .. suffix], 'Neovim temporary workspaces must not appear')
end
trust_before = table.concat(vim.fn.readfile(trust_path), '\n')

local rows = entries()
assert(rows[parent].mode == 'all' and rows[parent].source == 'configured')
assert(rows[sibling].mode == 'all' and rows[sibling].origin == parent)
assert(rows[child].mode == 'untrusted' and rows[child].source == 'saved')
assert(rows[nested].mode == 'untrusted' and rows[nested].origin == child)
assert(rows[old].mode == 'untrusted', 'legacy saved chats must be included')
assert(rows[removed].mode == 'untrusted', 'missing remembered workspaces must remain visible')
assert(vim.fn.getfperm(vim.fn.stdpath('data') .. '/codeit/seen_workspaces.json') == 'rw-------')
assert(select('#', approval.workspace_trust(nested)) == 1, 'keep the existing trust API single-valued')
package.loaded['codeit.workspaces'] = nil
workspaces = require('codeit.workspaces')
assert(entries()[nested], 'unsaved workspace visits must survive module reload')

local slash = require('codeit.commands.slash')
assert(slash.parse('/workspaces').command == 'CodeitWorkspaces')
assert(#slash.complete_items('/workspaces') == 1)
vim.cmd.CodeitWorkspaces()
local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
assert(vim.api.nvim_win_get_config(win).relative == 'editor')
assert(not vim.bo[buf].modifiable)
local function text() return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') end
assert(text():find(nested, 1, true) and text():find('Revoked in ' .. child, 1, true))
assert(text():find('configured in ' .. parent, 1, true))
assert(not text():find(temporary, 1, true) and not text():find(previous_temporary, 1, true))
assert(text():find('untrusted', 1, true) and text():find('all', 1, true))
assert(table.concat(vim.fn.readfile(trust_path), '\n') == trust_before, 'review must not change trust')
assert(codeit.workspaces() == win, 'reopening should focus the existing popup')
assert(not text():find('Includes saved chats and trust settings', 1, true))
assert(vim.api.nvim_buf_get_lines(buf, vim.api.nvim_win_get_cursor(win)[1] - 1,
  vim.api.nvim_win_get_cursor(win)[1], false)[1]:sub(1, 2) == '| ', 'initial selection must be a workspace row')
local highlight_ns = vim.api.nvim_get_namespaces().codeit_workspace_review
local function has_highlight(text, group)
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, highlight_ns, 0, -1, { details = true })) do
    local details = mark[4]
    local line = vim.api.nvim_buf_get_lines(buf, mark[2], mark[2] + 1, false)[1]
    if details.hl_group == group and line:sub(mark[3] + 1, details.end_col) == text then return true end
  end
  return false
end
assert(has_highlight('Workspaces', 'Title'))
assert(has_highlight(nested, 'Directory'))
assert(has_highlight('all', 'DiagnosticOk'))
assert(has_highlight('untrusted', 'DiagnosticError'))
assert(has_highlight('configured in ' .. parent, 'Comment'))
assert(has_highlight('|', 'CodeitTableBorder'))
assert(has_highlight('Read trust', 'CodeitTableHeader'))

local function press(key)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
    if map.lhs == key then return map.callback() end
  end
  error('missing mapping: ' .. key)
end
assert(approval.set_workspace_trust('tracked', nested))
press('r')
assert(text():find('tracked', 1, true) and text():find('saved here', 1, true))
assert(entries()[nested].mode == 'tracked')
assert(has_highlight('tracked', 'DiagnosticWarn'))
local marks = #vim.api.nvim_buf_get_extmarks(buf, highlight_ns, 0, -1, {})
press('r')
assert(#vim.api.nvim_buf_get_extmarks(buf, highlight_ns, 0, -1, {}) == marks,
  'refresh must replace highlights rather than accumulating them')
local function select_row(path)
  for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local prefix = '| ' .. path .. ' '
    if line:sub(1, #prefix) == prefix then
      vim.api.nvim_win_set_cursor(win, { row, 0 })
      return row
    end
  end
  error('missing workspace row: ' .. path)
end
local notices = {}
vim.notify = function(message) notices[#notices + 1] = message end
local choose
vim.ui.select = function(choices, opts, cb)
  assert(vim.deep_equal(choices, { 'all', 'tracked', 'untrusted' }))
  assert(opts.prompt:find(nested, 1, true))
  choose = cb
end
select_row(nested)
press('t')
choose(nil)
assert(entries()[nested].mode == 'tracked', 'cancelling must preserve trust')
press('t')
-- Capture the selected path, not the cwd or cursor when the picker completes.
vim.cmd.cd(old)
select_row(sibling)
choose('all')
assert(entries()[nested].mode == 'all' and entries()[old].mode == 'untrusted')
for _, mode in ipairs({ 'tracked', 'untrusted' }) do
  select_row(nested)
  press('t')
  choose(mode)
  assert(entries()[nested].mode == mode)
  assert(vim.api.nvim_win_get_cursor(win)[1] == select_row(nested), 'keep the selected row after refresh')
end
approval.setup({ trusted_workspaces = { [parent] = 'all' } })
assert(approval.workspace_trust(nested) == nil, 'revocation must persist and block inherited trust')
local save = approval.set_workspace_trust
approval.set_workspace_trust = function() return false, 'test save failure' end
press('t')
choose('all')
assert(notices[#notices]:find('test save failure', 1, true))
assert(entries()[nested].mode == 'untrusted')
approval.set_workspace_trust = save
vim.api.nvim_win_set_cursor(win, { 1, 0 })
press('t')
press('<CR>')
assert(vim.fn.getcwd() == old and notices[#notices]:find('select a workspace row', 1, true))
select_row(removed)
press('<CR>')
assert(vim.api.nvim_win_is_valid(win) and vim.fn.getcwd() == old)
assert(notices[#notices]:find('could not change directory', 1, true))
select_row(nested)
press('t')
press('q')
choose('all')
assert(approval.workspace_trust(nested) == nil, 'a closed picker must not change trust')
assert(not vim.api.nvim_win_is_valid(win) and not vim.api.nvim_buf_is_valid(buf))

-- :cd must affect the originating window, including a previous local cwd, and
-- escape special path characters rather than executing them as Ex commands.
local special = parent .. '/space | repo'
vim.fn.mkdir(special, 'p')
assert(workspaces.record(special))
local origin = vim.api.nvim_get_current_win()
vim.cmd('lcd ' .. vim.fn.fnameescape(old))
win, buf = codeit.workspaces()
assert(vim.api.nvim_win_is_valid(win) and vim.api.nvim_buf_is_valid(buf))
select_row(special)
press('<CR>')
assert(not vim.api.nvim_win_is_valid(win))
assert(vim.api.nvim_get_current_win() == origin and vim.fn.getcwd() == special)
assert(vim.fn.haslocaldir() == 0, ':cd should clear the originating window local directory')
assert(approval.workspace_trust(special) == 'all', 'switching directories must not change trust')
vim.cmd.cd(root)

-- Invalid registry content must not invent paths or prevent opening the review.
local seen_path = vim.fn.stdpath('data') .. '/codeit/seen_workspaces.json'
vim.fn.writefile({ vim.json.encode({ relative = true, [removed] = 'all' }) }, seen_path)
assert(not entries()[removed])
vim.fn.writefile({ '{invalid' }, seen_path)
assert(entries()[parent])
assert(workspaces.record(removed))
assert(entries()[removed])

vim.cmd.cd(root)
vim.fn.delete(parent, 'rf')
vim.fn.delete(old, 'rf')
vim.fn.delete(data, 'rf')
vim.fn.delete(temporary, 'rf')
print('codeit workspace review tests passed')
