vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.cmd('filetype on')
vim.cmd('syntax on')
local buffers = require('codeit.file_buffer')
local path = vim.fn.tempname() .. '.lua'
vim.fn.writefile({ 'local value = 1' }, path)
vim.cmd.edit(vim.fn.fnameescape(path))
local id = vim.api.nvim_get_current_buf()
vim.api.nvim_create_autocmd('FileType', {
  buffer = id,
  callback = function()
    vim.treesitter.start(id, 'lua')
    vim.bo[id].syntax = 'lua'
  end,
})
vim.treesitter.start(id, 'lua')
vim.bo[id].syntax = 'lua'
local function highlighted()
  assert(vim.bo[id].filetype == 'lua' and vim.bo[id].syntax == 'lua')
  vim.api.nvim_buf_call(id, function()
    assert(vim.fn.synIDattr(vim.fn.synID(1, 1, true), 'name') == 'luaStatement',
      'refresh cleared syntax rules')
  end)
  assert(vim.treesitter.highlighter.active[id], 'refresh stopped Tree-sitter highlighting')
end
highlighted()

-- The first uncached read reloads even when the disk content has not changed.
buffers.refresh(id)
highlighted()
local tick = vim.api.nvim_buf_get_changedtick(id)
buffers.refresh(id)
assert(vim.api.nvim_buf_get_changedtick(id) == tick, 'cached reads should not reload')
highlighted()

-- Also cover a hidden buffer and same-sized external changes.
vim.cmd.enew()
vim.bo[id].readonly, vim.bo[id].modifiable = true, false
vim.fn.writefile({ 'local value = 2' }, path)
buffers.refresh(id)
assert(vim.api.nvim_buf_get_lines(id, 0, -1, false)[1] == 'local value = 2')
assert(vim.bo[id].readonly and not vim.bo[id].modifiable)
highlighted()

vim.bo[id].modifiable = true
vim.api.nvim_buf_set_lines(id, 0, -1, false, { 'local value = 3' })
vim.fn.writefile({ 'local value = 4' }, path)
buffers.refresh(id)
assert(vim.api.nvim_buf_get_lines(id, 0, -1, false)[1] == 'local value = 3')
assert(vim.bo[id].modified)
highlighted()
vim.api.nvim_buf_delete(id, { force = true })
vim.fn.delete(path)

-- Ordinary buffers include unnamed drafts and read-only files, not explorers.
local unnamed = vim.api.nvim_create_buf(true, false)
vim.bo[unnamed].readonly, vim.bo[unnamed].modifiable = true, false
assert(buffers.ordinary(unnamed) and buffers.target({ buffer_id = unnamed }) == unnamed)
local special = vim.api.nvim_create_buf(false, true)
assert(not buffers.ordinary(special))
vim.bo[special].buftype = ''
vim.bo[special].filetype = 'netrw'
assert(not buffers.ordinary(special), 'netrw must be excluded even without a directory name')
local directory = vim.fn.tempname()
vim.fn.mkdir(directory, 'p')
vim.bo[special].filetype = ''
vim.api.nvim_buf_set_name(special, directory)
vim.api.nvim_buf_set_lines(special, 0, -1, false, { 'directory listing' })
vim.bo[special].modified = false
assert(not buffers.ordinary(special), 'directories must be excluded even without netrw filetype')
assert(not buffers.target({ buffer_id = special }))
local tick_before = vim.api.nvim_buf_get_changedtick(special)
buffers.refresh(special)
assert(vim.api.nvim_buf_get_changedtick(special) == tick_before)
assert(buffers.disk_version(special) == '')
for _, entry in ipairs(buffers.list(nil, true)) do assert(entry.id ~= special) end
vim.api.nvim_buf_delete(special, { force = true })
vim.api.nvim_buf_delete(unnamed, { force = true })
vim.fn.delete(directory, 'd')
