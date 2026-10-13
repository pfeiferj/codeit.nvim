vim.opt.runtimepath:prepend(vim.fn.getcwd())
local root = vim.fn.getcwd()
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
vim.fn.writefile({ 'tracked text' }, dir .. '/tracked.txt')
vim.fn.writefile({ 'private text' }, dir .. '/private.txt')
assert(vim.fn.system({ 'git', '-C', dir, 'init', '-q' }) == '')
assert(vim.fn.system({ 'git', '-C', dir, 'add', 'tracked.txt' }) == '')
vim.cmd.cd(dir)
local ui = require('codeit.ui')
local layout = require('codeit.ui.managed_tab')
local tools = require('codeit.tools')
local approval = require('codeit.tools.approval.prompt')
local original_tab, original_win = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win()
local source = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(source, 0, -1, false, { 'unsaved user text' })
local prompted, decision, pending = false, 'reject', nil
approval.show = function(_, _, cb)
  prompted = true
  if decision == 'wait' then pending = cb else cb(decision) end
end
vim.ui.input = function(_, cb) cb(nil) end
local function call(name, args, prompt)
  prompted = false
  local result
  tools.execute(name, args or {}, source, function(value) result = value end, function() return true end)
  assert(vim.wait(5000, function() return result ~= nil end), 'timeout: ' .. name)
  assert(prompted == (prompt or false), name .. ': unexpected approval: ' .. result)
  return result
end
local function json(name, args) local result = call(name, args); assert(not result:match('^Error:'), result); return vim.json.decode(result) end
local function error_call(name, args) assert(call(name, args):match('^Error:')) end
local function policy(mode, validators) tools.configure({ trusted_workspaces = mode and { [dir] = mode } or {}, validators = validators }) end
policy(nil)
ui.open(function() end, ui.close)
local tab = layout.tab()
assert(tab ~= original_tab and vim.api.nvim_win_is_valid(original_win))
assert(#vim.api.nvim_tabpage_list_wins(original_tab) == 1)
local win = layout.windows()[1]
assert(layout.buffer(win) == source and layout.user_visible(source))
assert(json('read_window_buffer', { window_id = win, start_line = '', end_line = '' }).lines[1] == 'unsaved user text')
assert(vim.json.decode(call('read_loaded_buffer', { buffer_id = source })).lines[1] == 'unsaved user text')
assert(vim.json.decode(call('read_source_buffer')).modified)
local chat = vim.fn.bufwinid('codeit://chat')
error_call('focus_window', { window_id = original_win })
error_call('close_window', { window_id = chat })
error_call('read_window_buffer', { window_id = chat })
local blank = json('close_window', { window_id = win })
assert(blank.window_id == win and blank.buffer_id ~= source and not blank.user_attached)
assert(#layout.windows() == 1 and vim.api.nvim_win_is_valid(chat))
assert(vim.api.nvim_buf_get_name(blank.buffer_id) == '' and vim.bo[blank.buffer_id].buftype == '')
assert(vim.bo[blank.buffer_id].buflisted and not vim.bo[blank.buffer_id].modified)
assert(vim.api.nvim_buf_get_lines(blank.buffer_id, 0, -1, false)[1] == '')
assert(vim.bo[source].modified and vim.api.nvim_buf_get_lines(source, 0, -1, false)[1] == 'unsaved user text')
vim.api.nvim_win_set_buf(win, source)
error_call('split_window', { window_id = win, direction = 'bad' })
error_call('open_window_file', { window_id = win, path = 'missing' })
error_call('resize_window', { window_id = win })
local default_split = json('split_window', { window_id = win, direction = '' })
assert(default_split.buffer_id == source and #layout.windows() == 2)
json('close_window', { window_id = default_split.window_id })
local opened = json('open_window_file', { window_id = win, path = 'private.txt' })
assert(not layout.user_visible(opened.buffer_id))
for _, path in ipairs({ 'private.txt', './private.txt', dir .. '/private.txt' }) do
  assert(json('open_window_file', { window_id = win, path = path }).buffer_id == opened.buffer_id)
end
assert(vim.uv.fs_symlink(dir .. '/private.txt', dir .. '/private-link.txt'))
local linked = json('open_window_file', { window_id = win, path = 'private-link.txt' })
assert(vim.uv.fs_realpath(vim.api.nvim_buf_get_name(linked.buffer_id)) == dir .. '/private.txt')
assert(json('open_window_buffer', { window_id = win, buffer_id = opened.buffer_id }).buffer_id == opened.buffer_id)
local file_split = json('split_window_file', { window_id = win, path = 'private.txt' })
assert(file_split.buffer_id == opened.buffer_id and not file_split.user_attached)
json('close_window', { window_id = file_split.window_id })
local buffer_split = json('split_window_buffer', { window_id = win, buffer_id = opened.buffer_id })
assert(buffer_split.buffer_id == opened.buffer_id and not buffer_split.user_attached)
call('read_window_buffer', { window_id = buffer_split.window_id }, true)
json('close_window', { window_id = buffer_split.window_id })
for _, name in ipairs({ 'open_window_file', 'split_window_file' }) do
  error_call(name, { window_id = win })
  error_call(name, { window_id = win, path = '' })
  error_call(name, { window_id = win, path = 'missing' })
  error_call(name, { window_id = win, path = vim.fn.tempname() })
  error_call(name, { window_id = win, path = 'private.txt', buffer_id = opened.buffer_id })
  assert(layout.buffer(win) == opened.buffer_id and #layout.windows() == 1)
end
for _, name in ipairs({ 'open_window_buffer', 'split_window_buffer' }) do
  error_call(name, { window_id = win })
  error_call(name, { window_id = win, buffer_id = '' })
  error_call(name, { window_id = win, buffer_id = 999999 })
  error_call(name, { window_id = win, buffer_id = vim.api.nvim_win_get_buf(chat) })
  error_call(name, { window_id = win, buffer_id = opened.buffer_id, path = 'private.txt' })
  assert(layout.buffer(win) == opened.buffer_id and #layout.windows() == 1)
end
error_call('split_window', { window_id = win, path = 'private.txt' })
error_call('split_window', { window_id = win, buffer_id = opened.buffer_id })
assert(vim.bo[source].modified and vim.api.nvim_buf_get_lines(source, 0, -1, false)[1] == 'unsaved user text')
call('read_window_buffer', { window_id = win }, true)
call('read_loaded_buffer', { buffer_id = opened.buffer_id }, true)
json('focus_window', { window_id = win })
call('read_window_buffer', { window_id = win }, true)
local split = json('split_window_file', { window_id = win, direction = 'vertical', path = 'tracked.txt' })
assert(#layout.windows() == 2 and split.window_id ~= win)
assert(vim.api.nvim_get_current_win() == win, 'splitting must not steal focus')
assert(not split.user_attached)
call('read_window_buffer', { window_id = split.window_id }, true)
policy('tracked')
assert(json('read_window_buffer', { window_id = split.window_id }).lines[1] == 'tracked text')
call('read_window_buffer', { window_id = win }, true)
policy('all')
assert(json('read_window_buffer', { window_id = win }).lines[1] == 'private text')
policy(nil)
-- User switches buffers in an assistant-created window; that attachment is consent.
vim.api.nvim_win_set_buf(win, source)
assert(layout.user_visible(source))
assert(json('read_window_buffer', { window_id = win }).modified)
json('open_window_buffer', { window_id = split.window_id, buffer_id = source })
assert(layout.user_visible(source), 'assistant attachment must not revoke another user-visible attachment')
json('open_window_file', { window_id = win, path = 'private.txt' })
assert(not layout.user_visible(source), 'consent requires a currently visible user attachment')
call('read_loaded_buffer', { buffer_id = source }, true)
local outside = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(outside, vim.fn.tempname())
vim.api.nvim_buf_set_lines(outside, 0, -1, false, { 'external edits' })
vim.api.nvim_win_set_buf(win, outside)
assert(json('read_window_buffer', { window_id = win }).lines[1] == 'external edits')
json('open_window_buffer', { window_id = win, buffer_id = outside })
call('read_window_buffer', { window_id = win }, true)
-- User-created inherited splits must not launder assistant attachment provenance.
vim.api.nvim_set_current_win(win)
vim.cmd('split')
local inherited = vim.api.nvim_get_current_win()
assert(not layout.user_visible(outside))
call('read_window_buffer', { window_id = inherited }, true)
json('close_window', { window_id = inherited })
assert(vim.bo[outside].modified)
vim.bo[outside].bufhidden = 'wipe'
error_call('open_window_buffer', { window_id = win, buffer_id = source })
error_call('open_window_file', { window_id = win, path = 'private.txt' })
error_call('close_window', { window_id = win })
assert(vim.api.nvim_buf_is_valid(outside) and vim.bo[outside].modified)
vim.bo[outside].bufhidden = ''
-- Window reads keep the existing bounded-read and edit-revision contracts.
local lines = {}
for i = 1, 250 do lines[i] = 'line ' .. i end
vim.api.nvim_buf_set_lines(outside, 0, -1, false, lines)
vim.api.nvim_win_set_buf(win, source)
vim.api.nvim_win_set_buf(win, outside)
local versions, page = {}, nil
tools.execute('read_window_buffer', { window_id = win }, source,
  function(value) page = vim.json.decode(value) end, function() return true end, { read_versions = versions })
assert(page and #page.lines == 200 and page.truncated and page.next_start_line == 201)
assert(require('codeit.file_buffer').was_read(outside, versions))
assert(#json('read_window_buffer', { window_id = win, start_line = 201 }).lines == 50)
error_call('read_window_buffer', { window_id = win, start_line = 4, end_line = 2 })
json('open_window_buffer', { window_id = win, buffer_id = outside })
-- Navigation changes only the target view, never focus, text, or read consent.
vim.api.nvim_set_current_win(chat)
local other_cursor = vim.api.nvim_win_get_cursor(split.window_id)
local tick = vim.api.nvim_buf_get_changedtick(outside)
local positioned = json('set_window_cursor', { window_id = win, line = 120, column = 3 })
assert(positioned.cursor_line == 120 and positioned.cursor_column == 3)
local target_row = math.max(1, math.floor(vim.api.nvim_win_get_height(win) / 4))
assert(positioned.top_line == 120 - target_row + 1)
assert(vim.api.nvim_win_call(win, function() return vim.fn.winline() end) == target_row)
local scrolled = json('scroll_window', { window_id = win, lines = 5 })
assert(scrolled.top_line == positioned.top_line + 5)
assert(json('scroll_window', { window_id = win, lines = -5 }).top_line == positioned.top_line)
assert(json('scroll_window', { window_id = win, lines = 0 }).top_line == positioned.top_line)
assert(json('set_window_cursor', { window_id = win, line = 120, column = 999 }).cursor_column == #lines[120])
local unpositioned = json('set_window_cursor', { window_id = win, line = 120, center = false })
assert(unpositioned.cursor_column == 1 and unpositioned.top_line == positioned.top_line)
vim.api.nvim_win_call(win, function()
  vim.wo.foldmethod = 'manual'
  vim.cmd('110,130fold')
end)
json('set_window_cursor', { window_id = win, line = 120 })
assert(vim.api.nvim_win_call(win, function() return vim.fn.foldclosed(120) end) == -1)
assert(vim.api.nvim_win_call(win, function() return vim.fn.winline() end) == target_row)
assert(json('set_window_cursor', { window_id = win, line = 1 }).top_line == 1)
assert(json('scroll_window', { window_id = win, lines = -1000 }).top_line == 1)
json('set_window_cursor', { window_id = win, line = 250 })
local bottom = json('scroll_window', { window_id = win, lines = 1000 })
assert(bottom.top_line >= 1 and bottom.top_line <= 250)
assert(json('scroll_window', { window_id = win, lines = 1000 }).top_line == bottom.top_line)
for _, args in ipairs({ { window_id = win }, { window_id = win, line = 0 },
  { window_id = win, line = 251 }, { window_id = win, line = 1, column = 0 },
  { window_id = win, line = 1.5 }, { window_id = chat, line = 1 },
  { window_id = original_win, line = 1 } }) do
  error_call('set_window_cursor', args)
end
for _, args in ipairs({ { window_id = win }, { window_id = win, lines = 1.5 },
  { window_id = chat, lines = 1 }, { window_id = original_win, lines = 1 } }) do
  error_call('scroll_window', args)
end
assert(vim.api.nvim_get_current_win() == chat, 'navigation must not steal focus')
assert(vim.deep_equal(vim.api.nvim_win_get_cursor(split.window_id), other_cursor))
assert(vim.api.nvim_buf_get_changedtick(outside) == tick and vim.bo[outside].modified)
assert(not layout.user_visible(outside), 'navigation must not grant read consent')
-- Position by displayed rows, including wrapped lines and continuation columns.
local window_options = {}
for _, name in ipairs({ 'wrap', 'smoothscroll', 'linebreak', 'breakindent', 'showbreak' }) do
  window_options[name] = vim.api.nvim_get_option_value(name, { win = win })
end
vim.wo[win].wrap, vim.wo[win].linebreak, vim.wo[win].breakindent = true, false, false
vim.wo[win].showbreak = ''
local text_width = vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff
local wrapped_lines = {}
for i = 1, 250 do wrapped_lines[i] = string.rep('x', text_width + 1) end
vim.api.nvim_buf_set_lines(outside, 0, -1, false, wrapped_lines)
for _, smooth in ipairs({ false, true }) do
  vim.wo[win].smoothscroll = smooth
  for _, column in ipairs({ 1, text_width + 1 }) do
    local wrapped = json('set_window_cursor', { window_id = win, line = 120, column = column })
    assert(wrapped.cursor_line == 120 and wrapped.cursor_column == column)
    local row = vim.api.nvim_win_call(win, function() return vim.fn.winline() end)
    assert(math.abs(row - target_row) <= 1, 'wrapped target must be near the quarter-height row')
    assert(vim.wo[win].smoothscroll == smooth)
  end
end
-- A preceding line taller than the window must not push the cursor off its target.
vim.wo[win].smoothscroll = false
vim.api.nvim_buf_set_lines(outside, 118, 119, false,
  { string.rep('x', text_width * vim.api.nvim_win_get_height(win) * 2) })
local tall = json('set_window_cursor', { window_id = win, line = 120 })
assert(tall.cursor_line == 120 and tall.cursor_column == 1)
assert(vim.api.nvim_win_call(win, function() return vim.fn.winline() end) == 1)
assert(json('set_window_cursor', { window_id = win, line = 1 }).top_line == 1)
for name, value in pairs(window_options) do vim.api.nvim_set_option_value(name, value, { win = win }) end
assert(vim.api.nvim_get_current_win() == chat, 'wrapped navigation must not steal focus')
assert(not layout.user_visible(outside), 'wrapped navigation must not grant read consent')
call('read_window_buffer', { window_id = win }, true)
local resized = json('resize_window', { window_id = split.window_id, width = 20, height = 5 })
assert(resized.width >= 1 and resized.height >= 1)
assert(#json('list_windows').windows == 2)
-- Even auto-approved layout operations honor validators.
policy(nil, { function() return 'reject' end })
assert(call('focus_window', { window_id = win }):match('^Rejected'))
assert(call('set_window_cursor', { window_id = win, line = 1 }):match('^Rejected'))
assert(call('scroll_window', { window_id = win, lines = 1 }):match('^Rejected'))
policy(nil, { function() return 'ask' end })
call('list_windows', {}, true)
policy(nil)
-- Approval must apply to the buffer that was shown when the read was requested.
decision = 'wait'
local result
local reads = {}
tools.execute('read_window_buffer', { window_id = win }, source, function(value) result = value end,
  function() return true end, { read_versions = reads })
assert(pending)
vim.api.nvim_win_set_buf(win, source)
pending('once')
assert(result:match('^Error: window buffer changed'))
assert(not next(reads))
decision = 'reject'
ui.close()
assert(vim.api.nvim_get_current_tabpage() == original_tab and layout.tab() == tab)
assert(vim.bo[source].modified and vim.bo[outside].modified)
ui.open(function() end, ui.close)
assert(layout.tab() == tab and #layout.windows() == 2)
assert(json('read_window_buffer', { window_id = win }).modified)
policy(nil, { function() return 'ask' end })
call('read_window_buffer', { window_id = win }, true)
policy(nil)
json('close_window', { window_id = split.window_id })
assert(json('close_window', { window_id = win }).window_id == win)
assert(vim.bo[source].modified)
vim.api.nvim_win_set_buf(win, source)
ui.close()
-- Closing the managed tab manually invalidates all visibility-based consent.
vim.cmd('tabclose! ' .. vim.api.nvim_tabpage_get_number(tab))
assert(not layout.user_visible(source))
ui.open(function() end, ui.close)
assert(layout.tab() ~= tab)
ui.close()
local plugin = require('codeit')
plugin.setup({})
plugin.open()
local managed = layout.tab()
vim.api.nvim_set_current_tabpage(original_tab)
plugin.toggle()
assert(vim.api.nvim_get_current_tabpage() == managed and ui.is_open(), 'toggle from another tab must focus Codeit')
plugin.toggle()
assert(not ui.is_open() and vim.api.nvim_get_current_tabpage() == original_tab)
-- Startup screens must leave an ordinary file pane for the window tools.
for _, startup in ipairs({ 'empty', 'dashboard', 'dashboard_autocmd' }) do
  vim.cmd('tabclose! ' .. vim.api.nvim_tabpage_get_number(layout.tab()))
  local initial = vim.api.nvim_create_buf(true, startup ~= 'empty')
  vim.api.nvim_win_set_buf(original_win, initial)
  local entered = false
  if startup == 'dashboard_autocmd' then
    vim.api.nvim_create_autocmd('TabEnter', {
      once = true,
      callback = function()
        entered = true
        vim.api.nvim_win_set_buf(0, initial)
      end,
    })
  end
  ui.open(function() end, ui.close)
  assert(startup ~= 'dashboard_autocmd' or entered)
  local windows = json('list_windows').windows
  assert(#windows == 1, startup .. ': missing ordinary file pane')
  local pane = windows[1]
  assert(vim.bo[pane.buffer_id].buftype == '' and vim.bo[pane.buffer_id].buflisted)
  assert(vim.api.nvim_buf_get_name(pane.buffer_id) == '')
  assert(vim.api.nvim_buf_get_lines(pane.buffer_id, 0, -1, false)[1] == '')
  assert((pane.buffer_id == initial) == (startup == 'empty'))
  assert(vim.api.nvim_win_get_buf(original_win) == initial)
  assert(#vim.api.nvim_tabpage_list_wins(original_tab) == 1)
  local file = json('open_window_file', { window_id = pane.window_id, path = 'private.txt' })
  assert(layout.buffer(pane.window_id) == file.buffer_id and not file.user_attached)
  assert(not layout.user_visible(file.buffer_id))
  call('read_window_buffer', { window_id = pane.window_id }, true)
  ui.close()
  assert(vim.api.nvim_get_current_tabpage() == original_tab)
  assert(vim.api.nvim_win_get_buf(original_win) == initial)
end
vim.api.nvim_win_set_buf(original_win, source)
assert(vim.bo[source].modified and vim.api.nvim_buf_get_lines(source, 0, -1, false)[1] == 'unsaved user text')
vim.cmd.cd(root)
vim.fn.delete(dir, 'rf')
print('codeit managed tab tests passed')
