vim.opt.runtimepath:prepend(vim.fn.getcwd())
local picker = require('codeit.history_picker')
local summary = 'Implemented the requested changes and verified that the long LLM summary remains readable.'
local entries = {
  { id = 'first', updated_at = 1000000000, summary = summary },
  { id = 'second', updated_at = 999999999 },
}
local chosen, calls
local function show(items)
  chosen, calls = nil, 0
  picker.show(items, '/a/workspace', function(chat)
    calls = calls + 1
    chosen = chat
  end)
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  assert(vim.bo[buf].filetype == 'codeit' and vim.bo[buf].syntax == 'codeit')
  assert(vim.b[buf].current_syntax == 'codeit', 'history picker should load Codeit highlighting')
  vim.api.nvim_win_call(win, function()
    assert(vim.fn.synIDattr(vim.fn.synID(1, 1, true), 'name') ~= '',
      'history heading should have active Markdown highlighting')
    assert(vim.fn.synIDattr(vim.fn.synID(3, 3, true), 'name') ~= '',
      'history entries should have active Markdown highlighting')
  end)
  local config = vim.api.nvim_win_get_config(win)
  assert(config.relative == 'editor' and config.width >= math.floor(vim.o.columns * 0.8),
    'history picker should occupy most of the editor width')
  assert(config.height <= vim.o.lines - 4)
  if #items == 2 then
    assert(config.height > #items + 2, 'wrapped summaries should have enough vertical room to read')
  end
  assert(vim.wo[win].wrap and vim.wo[win].linebreak)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  assert(lines[1] == '# Resume chat for /a/workspace')
  assert(lines[3] == '- **' .. os.date('%Y-%m-%d %H:%M', items[1].updated_at) .. '**  ' .. summary)
  assert(lines[4] == '- **' .. os.date('%Y-%m-%d %H:%M', items[2].updated_at) .. '**'
    .. (items[2].summary and '  ' .. items[2].summary or ''),
    'each entry should display its timestamp and available summary')
  assert(vim.api.nvim_win_get_cursor(win)[1] == 3)
  return win, buf
end
local win, buf = show(entries)
vim.api.nvim_win_set_cursor(win, { 4, 0 })
vim.api.nvim_buf_call(buf, function() vim.cmd.normal('\r') end)
assert(calls == 1 and chosen == entries[2] and not vim.api.nvim_win_is_valid(win),
  'Enter should resume the chat under the cursor')
vim.wait(20)
assert(calls == 1, 'closing after selection should not trigger a second callback')
win, buf = show(entries)
vim.api.nvim_buf_call(buf, function() vim.cmd.normal('q') end)
assert(calls == 1 and chosen == nil and not vim.api.nvim_win_is_valid(win), 'q should dismiss the picker')
win = show(entries)
vim.api.nvim_win_close(win, true)
assert(vim.wait(100, function() return calls == 1 end) and chosen == nil,
  'closing the floating window should dismiss the picker exactly once')
local many = {}
for i = 1, 100 do many[i] = { id = tostring(i), updated_at = 1000000000 - i, summary = summary } end
win = show(many)
assert(vim.api.nvim_win_get_config(win).height < #many, 'long histories should scroll inside the picker')
vim.api.nvim_win_close(win, true)
-- Deletion is confirmed, refreshes the picker, and never resumes a chat.
vim.wait(20)
local select = vim.ui.select
local confirmation, deleted, fail_delete
vim.ui.select = function(options, _, callback)
  assert(options[1] == 'Cancel' and options[2] == 'Delete')
  confirmation = callback
end
calls, deleted = 0, 0
picker.show(entries, '/a/workspace', function() calls = calls + 1 end, function(chat)
  if fail_delete then return false, 'test deletion failure' end
  deleted = deleted + 1
  assert(chat.id == (deleted == 1 and 'first' or 'second'))
  return true
end)
win = vim.api.nvim_get_current_win()
buf = vim.api.nvim_win_get_buf(win)
local function press(key)
  vim.api.nvim_buf_call(buf, function() vim.cmd.normal(key) end)
end
assert(vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]:find('d: delete', 1, true))
press('d')
confirmation('Cancel')
assert(deleted == 0 and vim.api.nvim_buf_line_count(buf) == 4)
press('d')
confirmation(nil)
assert(deleted == 0)
local notify = vim.notify
local error_message
vim.notify = function(message) error_message = message end
fail_delete = true
press('d')
confirmation('Delete')
assert(deleted == 0 and vim.api.nvim_buf_line_count(buf) == 4 and error_message:find('test deletion failure', 1, true))
vim.notify = notify
fail_delete = false
press('d')
confirmation('Delete')
assert(deleted == 1 and calls == 0 and vim.api.nvim_win_is_valid(win))
assert(vim.api.nvim_buf_line_count(buf) == 3 and #entries == 2, 'deleting must not mutate the caller list')
press('d')
confirmation('Delete')
assert(deleted == 2 and vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1] == 'No saved chats.')
press('\r')
assert(calls == 0, 'Enter on the empty list must not resume or close')
press('q')
assert(calls == 1)
-- Visual-line deletion uses the active selection, including reversed ranges.
local bulk_entries = {
  { id = 'one', updated_at = 1000000000 },
  { id = 'two', updated_at = 999999900 },
  { id = 'three', updated_at = 999999800 },
}
local prompts, prompt, deleted_ids
local function show_bulk(failed_id, action)
  action = action or 'Delete'
  calls, prompts, deleted_ids = 0, 0, {}
  confirmation = nil
  vim.ui.select = function(options, opts, callback)
    assert(options[1] == 'Cancel' and options[2] == action)
    prompts = prompts + 1
    prompt, confirmation = opts.prompt, callback
  end
  local function remove(chat)
    if chat.id == failed_id then return false, 'test bulk ' .. action:lower() .. ' failure' end
    deleted_ids[#deleted_ids + 1] = chat.id
    return true
  end
  picker.show(bulk_entries, '/a/workspace', function() calls = calls + 1 end,
    action == 'Delete' and remove or nil, action == 'Archive' and remove or nil)
  win = vim.api.nvim_get_current_win()
  buf = vim.api.nvim_win_get_buf(win)
end
show_bulk()
press('Vjd')
assert(prompts == 1 and prompt == 'Permanently delete 2 chats?')
assert(vim.api.nvim_get_mode().mode == 'n', 'confirmation should leave Visual mode')
press('d')
assert(prompts == 1, 'pending confirmation must block another deletion')
confirmation('Cancel')
assert(#deleted_ids == 0 and vim.api.nvim_buf_line_count(buf) == 5)
press('Vjd')
confirmation(nil)
assert(#deleted_ids == 0 and vim.api.nvim_buf_line_count(buf) == 5)
-- Ignore headings and use the current anchor rather than marks from the previous selection.
vim.api.nvim_win_set_cursor(win, { 5, 0 })
press('Vkkkd')
assert(prompt == 'Permanently delete 3 chats?')
confirmation('Delete')
assert(table.concat(deleted_ids, ',') == 'one,two,three')
assert(#bulk_entries == 3 and calls == 0 and vim.api.nvim_win_is_valid(win))
assert(vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1] == 'No saved chats.')
assert(not vim.bo[buf].modifiable)
local previous_prompts = prompts
press('Vkd')
assert(prompts == previous_prompts, 'empty rows and headings must not prompt for deletion')
press('q')
vim.wait(20)

show_bulk('two')
vim.notify = function(message) error_message = message end
press('Vjd')
confirmation('Delete')
vim.notify = notify
assert(table.concat(deleted_ids, ',') == 'one' and error_message:find('test bulk delete failure', 1, true))
local remaining = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
assert(#remaining == 4 and remaining[3]:find(os.date('%Y-%m-%d %H:%M', bulk_entries[2].updated_at), 1, true))
assert(remaining[4]:find(os.date('%Y-%m-%d %H:%M', bulk_entries[3].updated_at), 1, true))
assert(vim.api.nvim_win_get_cursor(win)[1] == 3 and calls == 0)
press('q')
vim.wait(20)

show_bulk()
vim.api.nvim_win_set_cursor(win, { 1, 0 })
press('Vjd')
assert(prompts == 0, 'selecting only headers must not prompt')
vim.api.nvim_win_set_cursor(win, { 3, 0 })
press('Vjd')
press('q')
confirmation('Delete')
assert(#deleted_ids == 0 and calls == 1, 'closing the picker must cancel pending bulk deletion')
-- When both actions are available, confirmations cannot overlap or dispatch the wrong handler.
local removed = {}
vim.ui.select = function(options, _, callback)
  prompt, confirmation = options[2], callback
end
picker.show(bulk_entries, '/a/workspace', function() end, function(chat)
  removed[#removed + 1] = 'delete:' .. chat.id
  return true
end, function(chat)
  removed[#removed + 1] = 'archive:' .. chat.id
  return true
end)
win = vim.api.nvim_get_current_win()
buf = vim.api.nvim_win_get_buf(win)
press('a')
assert(prompt == 'Archive')
local archive_confirmation = confirmation
press('d')
assert(confirmation == archive_confirmation, 'pending archive must block deletion')
confirmation('Archive')
press('d')
assert(prompt == 'Delete')
local delete_confirmation = confirmation
press('a')
assert(confirmation == delete_confirmation, 'pending deletion must block archiving')
confirmation('Delete')
assert(table.concat(removed, ',') == 'archive:one,delete:two')
press('q')
vim.wait(20)

-- Archive supports normal and visual-line selection with the same safeguards as deletion.
show_bulk(nil, 'Archive')
assert(vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]:find('a: archive', 1, true))
press('a')
assert(prompt == 'Archive chat one?')
confirmation('Cancel')
assert(#deleted_ids == 0 and vim.api.nvim_buf_line_count(buf) == 5)
press('a')
confirmation(nil)
assert(#deleted_ids == 0)
press('a')
confirmation('Archive')
assert(table.concat(deleted_ids, ',') == 'one' and calls == 0 and vim.api.nvim_win_is_valid(win))
assert(#bulk_entries == 3 and vim.api.nvim_buf_line_count(buf) == 4)
vim.api.nvim_win_set_cursor(win, { 4, 0 })
press('Vkka')
assert(prompt == 'Archive 2 chats?' and vim.api.nvim_get_mode().mode == 'n')
local archive_prompts = prompts
press('a')
assert(prompts == archive_prompts, 'pending confirmation must block another archive')
confirmation('Archive')
assert(table.concat(deleted_ids, ',') == 'one,two,three')
assert(vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1] == 'No saved chats.')
press('Vka')
assert(prompts == archive_prompts, 'empty rows and headings must not prompt for archiving')
press('q')
vim.wait(20)

show_bulk('two', 'Archive')
vim.notify = function(message) error_message = message end
press('Vja')
confirmation('Archive')
vim.notify = notify
assert(table.concat(deleted_ids, ',') == 'one' and error_message:find('could not archive chat', 1, true))
assert(vim.api.nvim_buf_line_count(buf) == 4 and calls == 0)
press('a')
press('q')
confirmation('Archive')
assert(table.concat(deleted_ids, ',') == 'one' and calls == 1, 'closing cancels a pending archive')
vim.ui.select = select
print('codeit history picker tests passed')
