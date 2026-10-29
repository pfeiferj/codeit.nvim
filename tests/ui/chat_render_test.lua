vim.opt.runtimepath:prepend(vim.fn.getcwd())
local render = require('codeit.ui.chat_render')
local win = vim.api.nvim_get_current_win()
local buf = vim.api.nvim_get_current_buf()
local lines = { '# Chat', '', 'Visible **answer**', '**Activity**', 'secret tool result',
  'end activity', '', '| A | B |', '| --- | --- |', '| 1 | 2 |', '## Message', 'draft' }
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
vim.wo[win].foldmethod = 'manual'
vim.wo[win].foldenable = true
vim.cmd('4,6fold')
local cursor = vim.api.nvim_win_get_cursor(win)
local snapshot = render.snapshot(win, 10)
assert(snapshot:find('Visible **answer**', 1, true))
assert(snapshot:find('| 1 | 2 |', 1, true))
assert(not snapshot:find('secret', 1, true))
assert(not snapshot:find('Activity', 1, true))
assert(not snapshot:find('draft', 1, true))
assert(vim.deep_equal(cursor, vim.api.nvim_win_get_cursor(win)))
assert(vim.fn.foldclosed(5) == 4, 'snapshot must not change folds')
vim.cmd('normal! zR')
assert(render.snapshot(win, 10):find('secret tool result', 1, true))
assert(render.scroll_offset(0, -3, 200, 30) == 0)
assert(render.scroll_offset(0, 3, 200, 30) == 3)
assert(render.scroll_offset(0, math.huge, 200, 30) == 170)
assert(render.scroll_offset(170, -math.huge, 200, 30) == 0)
assert(render.scroll_offset(0, 50, 10, 30) == 0)

local original_system, original_executable = vim.system, vim.fn.executable
local original_notify = vim.notify
local jobs, images, warnings = {}, {}, {}
vim.notify = function(message) warnings[#warnings + 1] = message end
vim.fn.executable = function() return 1 end
package.loaded.image = {
  is_enabled = function() return true end,
  from_file = function(_, opts)
    local image = { image_width = 1000, image_height = 10000, opts = opts, draws = {} }
    function image:render(geometry) self.draws[#self.draws + 1] = geometry end
    function image:clear() self.cleared = true end
    images[#images + 1] = image
    return image
  end,
}
package.loaded['image.utils.term'] = { get_size = function() return { cell_width = 10, cell_height = 20 } end }
vim.system = function(argv, opts, callback)
  assert(argv[1] == 'node' and argv[2]:match('chat_render%.js$'))
  local request = vim.json.decode(opts.stdin)
  assert(request.markdown:find('Visible **answer**', 1, true))
  assert(not request.markdown:find('draft', 1, true))
  local job = { callback = callback, request = request }
  function job:kill() self.killed = true end
  jobs[#jobs + 1] = job
  return job
end
local api = {}
render.attach(api, { transcript_win = win, chat_lines = vim.list_slice(lines, 1, 10) }, {}, {})
api.render_chat()
local preview_win = vim.api.nvim_get_current_win()
assert(preview_win ~= win and #jobs == 1)
jobs[1].callback({ code = 0, stdout = '{}', stderr = '' })
assert(vim.wait(1000, function() return #images == 1 end))
assert(images[1].ignore_global_max_size, 'tall images must bypass global height limits')
assert(images[1].draws[1].y == 0)
local preview_buf = vim.api.nvim_win_get_buf(preview_win)
local mappings = vim.api.nvim_buf_get_keymap(preview_buf, 'n')
for _, mapping in ipairs(mappings) do
  if mapping.lhs == 'G' then mapping.callback() end
end
assert(images[1].draws[#images[1].draws].y < 0, 'scrolling translates instead of shrinking')
api.close_rendered_chat()
assert(images[1].cleared and not vim.api.nvim_win_is_valid(preview_win))
assert(vim.api.nvim_get_current_win() == win)
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines))

-- Closing a pending preview cancels its worker; a stale callback cannot reopen it.
api.render_chat()
api.close_rendered_chat()
assert(jobs[2].killed)
jobs[2].callback({ code = 0, stdout = '{}', stderr = '' })
vim.wait(50, function() return false end)
assert(#images == 1 and vim.api.nvim_get_current_win() == win)

api.render_chat()
jobs[3].callback({ code = 1, stderr = 'missing playwright' })
assert(vim.wait(1000, function() return #warnings > 0 end))
assert(warnings[#warnings]:find('missing playwright', 1, true))
assert(vim.api.nvim_get_current_win() == win)
vim.system, vim.fn.executable, vim.notify = original_system, original_executable, original_notify
print('chat_render_test: passed')
