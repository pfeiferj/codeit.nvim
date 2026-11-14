vim.opt.runtimepath:prepend(vim.fn.getcwd())

local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
local previous = vim.fn.getcwd()
vim.cmd.cd(root)
local function cleanup()
  vim.cmd.cd(previous)
  vim.fn.delete(root, 'rf')
end

local function write(path, data)
  local file = assert(io.open(path, 'wb'))
  file:write(data)
  file:close()
end

local images = require('codeit.images')
local png = '\137PNG\r\n\026\n' .. string.rep('x', 16)
write(root .. '/one.png', png)
local part, canonical = images.load('one.png')
assert(part and part.type == 'image_url')
assert(part.image_url.url:match('^data:image/png;base64,'))
assert(canonical == vim.uv.fs_realpath(root .. '/one.png'))
local outside, outside_error = images.load('/tmp/codeit-image-does-not-exist.png')
assert(not outside and outside_error == 'Path is outside the workspace')
assert(vim.uv.fs_symlink(root .. '/one.png', root .. '/link.png'))
local linked, linked_path = images.load('link.png')
assert(linked and linked_path == canonical)

write(root .. '/bad.png', 'not an image')
local invalid, invalid_error = images.load('bad.png')
assert(not invalid and invalid_error:find('Unsupported image format', 1, true))
local missing, missing_error = images.load('missing.png')
assert(not missing and missing_error == 'File does not exist')

local huge = io.open(root .. '/huge.png', 'wb')
huge:seek('set', images.max_size)
huge:write('x')
huge:close()
local oversized, oversized_error = images.load('huge.png')
assert(not oversized and oversized_error:find('10 MiB', 1, true))

local files = require('codeit.tools.workspace.files')
local result
files.execute('read_image', { path = 'one.png' }, function(value) result = value end)
assert(type(result) == 'table' and result[1].type == 'text' and result[2].type == 'image_url')
assert(result[2].image_url.url == part.image_url.url)

for extension, bytes in pairs({ jpg = '\255\216\255x', gif = 'GIF89a123', webp = 'RIFF1234WEBP123' }) do
  write(root .. '/format.' .. extension, bytes)
  assert(images.load('format.' .. extension))
end
local loaded = vim.fn.bufadd(root .. '/link.png')
vim.fn.bufload(loaded)
vim.bo[loaded].modified = true
local unsaved, unsaved_error = images.load('one.png')
assert(not unsaved and unsaved_error:find('unsaved buffer', 1, true))
vim.bo[loaded].modified = false

local external = vim.fn.tempname()
vim.fn.mkdir(external, 'p')
write(external .. '/outside.png', png)
assert(vim.uv.fs_symlink(external .. '/outside.png', root .. '/escape.png'))
assert(not images.load('escape.png'), 'symlinks must not escape trust boundaries')
local approval = require('codeit.tools.approval')
approval.set_workspace_trust('all', external)
assert(images.load(external .. '/outside.png'), 'trusted external image reads should work')

local tools = require('codeit.tools')
local prompts, choice = 0, 'reject'
require('codeit.ui.input').show = function(_, callback) callback(nil) end
require('codeit.tools.approval.prompt').show = function(_, _, callback)
  prompts = prompts + 1
  callback(choice)
end
local function run()
  local output
  tools.execute('read_image', { path = 'one.png' }, nil, function(value) output = value end, function() return true end)
  assert(vim.wait(5000, function() return output ~= nil end))
  return output
end
assert(run():match('^Rejected') and prompts == 1)
choice = 'once'
assert(type(run()) == 'table' and prompts == 2)
approval.set_workspace_trust('all', root)
assert(type(run()) == 'table' and prompts == 2, 'trusted image reads should auto-approve')
approval.set_workspace_trust(nil, root)
approval.set_workspace_trust(nil, external)
vim.fn.delete(external, 'rf')
cleanup()
print('images_test: ok')
