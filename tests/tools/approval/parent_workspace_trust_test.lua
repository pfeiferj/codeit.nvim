vim.opt.runtimepath:prepend(vim.fn.getcwd())
local approval = require('codeit.tools.approval')
local root = vim.fn.getcwd()
local parent = vim.fn.tempname()
local child = parent .. '/repo'
local nested = child .. '/nested'
local sibling = parent .. '/other'
local prefix = parent .. '-other'
for _, path in ipairs({ nested, sibling, prefix }) do vim.fn.mkdir(path, 'p') end
parent = vim.uv.fs_realpath(parent)
child, nested, sibling = parent .. '/repo', parent .. '/repo/nested', parent .. '/other'
prefix = vim.uv.fs_realpath(prefix)

approval.setup({ trusted_workspaces = { [parent] = 'all' } })
assert(approval.workspace_trust(parent) == 'all')
assert(approval.workspace_trust(child) == 'all')
assert(approval.workspace_trust(nested) == 'all')
assert(approval.workspace_trust(sibling) == 'all')
assert(approval.workspace_trust(prefix) == nil, 'path prefixes must not inherit trust')
assert(approval.workspace_trust(vim.fn.fnamemodify(parent, ':h')) == nil)
vim.cmd.cd(nested)
assert(approval.workspace_trust() == 'all')

approval.setup({ trusted_workspaces = { [parent] = 'all', [child] = 'tracked' } })
assert(approval.workspace_trust(nested) == 'tracked', 'nearest configured entry wins')
assert(approval.set_workspace_trust('all', child))
assert(approval.workspace_trust(nested) == 'all', 'saved choice overrides the same configured directory')
assert(approval.set_workspace_trust(nil, child))
assert(approval.workspace_trust(child) == nil)
assert(approval.workspace_trust(nested) == nil, 'revocation blocks inherited trust')
assert(approval.workspace_trust(sibling) == 'all', 'revocation must not affect siblings')
assert(approval.set_workspace_trust('tracked', nested))
assert(approval.workspace_trust(nested) == 'tracked', 'explicit descendant trust overrides revocation')

approval.setup({ trusted_workspaces = { [parent] = 'all' } })
assert(approval.workspace_trust(child) == nil, 'revocation survives reload')
assert(approval.workspace_trust(nested) == 'tracked', 'saved trust survives reload')
assert(approval.set_workspace_trust('tracked', parent))
approval.setup({})
assert(approval.workspace_trust(sibling) == 'tracked', 'saved parent trust is inherited after reload')
approval.setup({ trusted_workspaces = { [sibling] = 'all' } })
assert(approval.workspace_trust(sibling) == 'all', 'closer configuration overrides saved ancestor')

local alias = prefix .. '/alias'
assert(vim.uv.fs_symlink(parent, alias))
approval.setup({ trusted_workspaces = { [alias] = 'all' } })
vim.cmd.cd(alias .. '/other')
assert(approval.workspace_trust() == 'tracked', 'saved trust uses the resolved parent path')
assert(approval.set_workspace_trust(nil, parent))
assert(approval.workspace_trust() == nil)

approval.setup({ trusted_workspaces = { ['/'] = 'all' } })
assert(approval.workspace_trust('/') == 'all', 'filesystem root can be trusted')
assert(approval.workspace_trust(prefix) == 'all', 'root trust extends to descendants')
assert(approval.workspace_trust(child) == nil, 'revocation still overrides root trust')

vim.cmd.cd(root)
vim.fn.delete(parent, 'rf')
vim.fn.delete(prefix, 'rf')
print('codeit parent workspace trust tests passed')
