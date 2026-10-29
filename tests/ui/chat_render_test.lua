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
local jobs, terminals, warnings = {}, {}, {}
local kitty = require('codeit.ui.kitty')
local original_open = kitty.open
vim.notify = function(message) warnings[#warnings + 1] = message end
vim.fn.executable = function() return 1 end
kitty.open = function()
  local terminal = { writes = {} }
  function terminal:measure(callback) callback({ cell_width = 10, cell_height = 20 }) end
  function terminal:write(sequence) self.writes[#self.writes + 1] = sequence end
  function terminal:close() self.closed = true end
  terminals[#terminals + 1] = terminal
  return terminal
end
vim.system = function(argv, opts, callback)
  assert(argv[1] == 'node' and argv[2]:match('chat_render%.js$'))
  local request = vim.json.decode(opts.stdin)
  assert(request.markdown:find('Visible **answer**', 1, true))
  assert(not request.markdown:find('draft', 1, true))
  local job = { callback = callback, request = request }
  function job:kill() self.killed = true end
  jobs[#jobs + 1] = job
  vim.fn.writefile({ 'fake PNG bytes' }, request.output, 'b')
  return job
end
local api = {}
render.attach(api, { transcript_win = win, chat_lines = vim.list_slice(lines, 1, 10) }, {}, {})
api.render_chat()
local preview_win = vim.api.nvim_get_current_win()
assert(preview_win ~= win and #jobs == 1)
jobs[1].callback({ code = 0, stdout = vim.json.encode({ width = jobs[1].request.width, height = 10000 }), stderr = '' })
assert(vim.wait(1000, function() return #terminals[1].writes >= 3 end))
local function placement(terminal)
  for i = #terminal.writes, 1, -1 do
    if terminal.writes[i]:find('a=p,', 1, true) then return terminal.writes[i] end
  end
end
assert(placement(terminals[1]):find('y=0,', 1, true))
assert(vim.fn.filereadable(jobs[1].request.output) == 0, 'delete PNG after upload')
local preview_buf = vim.api.nvim_win_get_buf(preview_win)
local mappings = vim.api.nvim_buf_get_keymap(preview_buf, 'n')
for _, mapping in ipairs(mappings) do
  if mapping.lhs == 'G' then mapping.callback() end
end
local last = placement(terminals[1])
assert(tonumber(last:match(',y=(%d+),')) > 0, 'scrolling updates the source crop')
assert(not last:match(',[cr]='), 'never request image scaling')
local upload_count = 0
for _, sequence in ipairs(terminals[1].writes) do
  if sequence:find('a=t,', 1, true) then upload_count = upload_count + 1 end
end
assert(upload_count == 1, 'scrolling must not upload the PNG again')
api.close_rendered_chat()
assert(terminals[1].closed and not vim.api.nvim_win_is_valid(preview_win))
assert(terminals[1].writes[#terminals[1].writes]:find('a=d,d=I,i=', 1, true))
assert(vim.api.nvim_get_current_win() == win)
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines))

-- Closing a pending preview cancels its worker; a stale callback cannot reopen it.
api.render_chat()
api.close_rendered_chat()
assert(jobs[2].killed)
jobs[2].callback({ code = 0, stdout = '{}', stderr = '' })
vim.wait(50, function() return false end)
assert(#terminals[2].writes == 0 and terminals[2].closed and vim.api.nvim_get_current_win() == win)
assert(vim.fn.filereadable(jobs[2].request.output) == 0)

api.render_chat()
jobs[3].callback({ code = 1, stderr = 'missing playwright' })
assert(vim.wait(1000, function() return #warnings > 0 end))
assert(warnings[#warnings]:find('missing playwright', 1, true))
assert(vim.api.nvim_get_current_win() == win)
-- Invalid renderer output must close the transport, not leave an image overlay.
local warning_count = #warnings
api.render_chat()
jobs[4].callback({ code = 0, stdout = '{}', stderr = '' })
assert(vim.wait(1000, function() return #warnings > warning_count end))
assert(terminals[4].closed)
assert(vim.fn.filereadable(jobs[4].request.output) == 0)

-- Pixel-size discovery can be asynchronous; closing cancels it and stale
-- responses must not launch a renderer.
local measured
kitty.open = function()
  local terminal = {}
  function terminal:measure(callback) measured = callback end
  function terminal:close() self.closed = true end
  return terminal
end
api.render_chat()
api.close_rendered_chat()
measured({ cell_width = 10, cell_height = 20 })
assert(#jobs == 4)
kitty.open = original_open
vim.system, vim.fn.executable, vim.notify = original_system, original_executable, original_notify
print('chat_render_test: passed')
