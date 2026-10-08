vim.opt.runtimepath:prepend(vim.fn.getcwd())
local plugin = require('codeit')
local approval = require('codeit.approval')
local root = vim.fn.getcwd()
local dir = vim.fn.tempname()
local other = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
vim.fn.mkdir(other, 'p')
vim.fn.writefile({ 'tracked' }, dir .. '/tracked.txt')
vim.fn.writefile({ 'untracked' }, dir .. '/untracked.txt')
assert(vim.fn.system({ 'git', '-C', dir, 'init', '-q' }) == '')
assert(vim.fn.system({ 'git', '-C', dir, 'add', 'tracked.txt' }) == '')
vim.cmd.cd(dir)
plugin.setup({ approval = { trusted_workspaces = { [dir] = 'all' } } })
local notices = {}
vim.notify = function(message) notices[#notices + 1] = message end
local function read(path, prompted)
  local selected, result = false, nil
  vim.ui.select = function(_, _, cb) selected = true; cb(nil) end
  approval.request('read_file', { path = path }, 'Read?', nil,
    function(value) result = value end, function() result = 'allowed' end)
  assert(selected == prompted, 'unexpected approval prompt for ' .. path)
  assert(result == (prompted and 'Rejected by user' or 'allowed'), tostring(result))
end

read('untracked.txt', false)
vim.cmd.CodeitUntrust()
assert(approval.workspace_trust() == nil)
read('tracked.txt', true)
-- Revocation must also override a trust entry supplied through setup after restart.
plugin.setup({ approval = { trusted_workspaces = { [dir] = 'all' } } })
read('tracked.txt', true)
vim.cmd('CodeitTrust tracked')
assert(approval.workspace_trust() == 'tracked')
read('tracked.txt', false)
read('untracked.txt', true)
approval.setup({}) -- simulate reloading the persisted trust file
assert(approval.workspace_trust() == 'tracked')
read('tracked.txt', false)
local select_callback
vim.ui.select = function(options, opts, cb)
  assert(vim.tbl_contains(options, 'all') and vim.tbl_contains(options, 'tracked'))
  assert(opts.prompt:find(dir, 1, true))
  select_callback = cb
end
vim.cmd.CodeitTrust()
assert(select_callback)
vim.cmd.cd(other)
select_callback('all')
assert(approval.workspace_trust() == nil, 'trust must apply to the directory shown in the picker')
vim.cmd.cd(dir)
assert(approval.workspace_trust() == 'all')
read('untracked.txt', false)
vim.cmd.CodeitTrustStatus()
assert(notices[#notices]:find('all', 1, true))
vim.cmd.CodeitUntrust()
approval.setup({}) -- verify revocation survives reload
assert(approval.workspace_trust() == nil)
read('tracked.txt', true)
assert(vim.fn.getfperm(vim.fn.stdpath('data') .. '/codeit/trusted_workspaces.json') == 'rw-------')
vim.cmd.cd(root)
vim.fn.delete(dir, 'rf')
vim.fn.delete(other, 'rf')
print('codeit trust command tests passed')
