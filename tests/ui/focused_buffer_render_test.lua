vim.opt.runtimepath:prepend(vim.fn.getcwd())
local render = require('codeit.ui.chat_render')
local kitty = require('codeit.ui.kitty')
local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
local original_system, original_executable, original_open, original_notify = vim.system, vim.fn.executable, kitty.open, vim.notify
local requests, jobs, warnings = {}, {}, {}
vim.fn.executable = function() return 1 end
vim.notify = function(message) warnings[#warnings + 1] = message end
kitty.open = function()
  local terminal = {}
  function terminal:measure(callback) callback({ cell_width = 10, cell_height = 20 }) end
  function terminal:close() self.closed = true end
  return terminal
end
vim.system = function(_, opts, callback)
  requests[#requests + 1] = vim.json.decode(opts.stdin)
  local job = { callback = callback }
  function job:kill() self.killed = true end
  jobs[#jobs + 1] = job
  return job
end
-- Deliberately no open chat: the generic renderer must not depend on it.
local api = {}
render.attach(api, {}, {}, {})
local function snapshot()
  local cursor, modified = vim.api.nvim_win_get_cursor(win), vim.bo[buf].modified
  local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  api.render_chat()
  assert(vim.api.nvim_get_current_win() ~= win)
  local request = requests[#requests]
  api.close_rendered_chat()
  local job = jobs[#jobs]
  assert(job.killed)
  job.callback({ code = 1, stderr = 'cancelled' })
  vim.wait(10, function() return false end)
  assert(vim.api.nvim_get_current_win() == win)
  assert(vim.deep_equal(before, vim.api.nvim_buf_get_lines(buf, 0, -1, false)))
  assert(vim.deep_equal(cursor, vim.api.nvim_win_get_cursor(win)))
  assert(vim.bo[buf].modified == modified, 'rendering must not save or alter the source')
  return request.markdown
end

vim.bo[buf].filetype = 'markdown'
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '# Unsaved document', '', '**Latest unsaved changes**', '## Message', 'Not a chat draft' })
assert(snapshot():find('Latest unsaved changes', 1, true))
assert(snapshot():find('Not a chat draft', 1, true), 'ordinary headings must not truncate Markdown')
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '# Document', 'hidden section', 'hidden body', '', 'visible tail' })
vim.wo[win].foldmethod = 'manual'
vim.cmd('2,3fold')
local text = snapshot()
assert(not text:find('hidden', 1, true) and text:find('visible tail', 1, true))
assert(vim.fn.foldclosed(2) == 2)
vim.cmd('normal! zR')

-- Recognize file extensions even when filetype detection is disabled.
vim.bo[buf].filetype = ''
vim.api.nvim_buf_set_name(buf, 'focused-render.MD')
assert(snapshot():find('# Document', 1, true))
-- Also accept unnamed Markdown buffers and Codeit compound filetypes.
vim.api.nvim_buf_set_name(buf, '')
vim.bo[buf].filetype = 'markdown.pandoc'
assert(render.source(win).buf == buf)
vim.bo[buf].filetype = 'codeit-settings'
assert(snapshot():find('# Document', 1, true))
-- Codeit pages may have JSON/text filetypes, such as context/system editors.
vim.api.nvim_buf_set_name(buf, 'codeit://context-full')
vim.bo[buf].filetype = 'json'
assert(snapshot():find('visible tail', 1, true))

-- Secondary chats carry their own cutoff, not the main controller's length.
vim.api.nvim_buf_set_name(buf, 'codeit://secondary-chat')
vim.b[buf].codeit_render_last_line = 1
assert(snapshot() == '# Document')
vim.b[buf].codeit_render_last_line = nil
-- A reused chat window displaying a Markdown file must not inherit a cutoff.
vim.api.nvim_buf_set_name(buf, 'reused-window.md')
local selected = render.source(win, { transcript_win = win, transcript = buf + 1000, chat_lines = { 'wrong' } })
assert(selected.last == nil)

-- Reject unrelated buffers instead of silently rendering a different chat.
vim.api.nvim_buf_set_name(buf, 'focused-render.lua')
vim.bo[buf].filetype = 'lua'
local before = #jobs
api.render_chat()
assert(#jobs == before and vim.api.nvim_get_current_win() == win)
assert(warnings[#warnings]:find('Focus a Codeit page or Markdown buffer', 1, true))
vim.system, vim.fn.executable, kitty.open, vim.notify = original_system, original_executable, original_open, original_notify
print('focused_buffer_render_test: passed')
