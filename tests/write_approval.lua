vim.opt.runtimepath:prepend(vim.fn.getcwd())
local popup = require('codeit.write_approval')
local options = {
  { key = '1', id = 'once', label = 'Approve once' },
  { key = '2', id = 'always', label = 'Always approve exact call' },
  { key = '3', id = 'reject', label = 'Reject' },
  { key = '4', id = 'cancel', label = 'Cancel' },
  { key = '5', id = 'review', label = 'Ask reviewer' },
}
local function open(before, after, path, warning)
  local calls, result = 0, nil
  local previous = vim.api.nvim_get_current_win()
  popup.show({ path = path or 'example.lua', before = before, after = after, warning = warning }, options, function(choice)
    calls, result = calls + 1, choice
  end)
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local maps = {}
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do maps[map.lhs] = map.callback end
  local function close(key, expected)
    maps[key]()
    assert(calls == 1 and result == expected and not vim.api.nvim_win_is_valid(win))
    assert(vim.api.nvim_get_current_win() == previous)
    vim.wait(20)
    assert(calls == 1, 'closing must decide only once')
  end
  return win, buf, lines, maps, close
end

local function title(win)
  local chunks = vim.api.nvim_win_get_config(win).title
  local text = {}
  for _, chunk in ipairs(chunks) do text[#text + 1] = chunk[1] end
  return table.concat(text)
end

local win, buf, lines, maps, close = open('local x = 1\nprint(x)\n', 'local x = 2\nprint(x)\n')
assert(title(win) == ' Review file edit: example.lua ', 'relative paths should appear in the title')
assert(vim.bo[buf].filetype == 'lua', 'the preview should use the source filetype')
local text = table.concat(lines, '\n')
assert(not text:find('Approve once', 1, true), 'options must be virtual')
assert(text:find('local x = 1\nlocal x = 2\nprint(x)', 1, true), 'show old and new text in the full file')
assert(not text:find('--- example.lua', 1, true) and not text:find('@@', 1, true), 'no patch metadata')
local namespaces = vim.api.nvim_get_namespaces()
local function header_marks(buffer)
  return vim.api.nvim_buf_get_extmarks(buffer, namespaces['codeit-write-approval-header'], 0, -1, { details = true })
end
local function assert_hunk_labels(buffer, first_lines)
  local marks = vim.api.nvim_buf_get_extmarks(buffer, namespaces['codeit-write-approval-hunks'],
    0, -1, { details = true })
  local contents = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
  assert(#marks == #first_lines, 'each hunk must have exactly one virtual label')
  for i, mark in ipairs(marks) do
    local details = mark[4]
    assert(contents[mark[2] + 1] == first_lines[i], 'label must be on the first line of the hunk')
    assert(mark[3] == 0 and details.virt_text_pos == 'eol', 'hunk labels must appear at end of line')
    assert(vim.deep_equal(details.virt_text, { { ' Hunk ' .. i .. '/' .. #first_lines, 'CodeitApprovalHunk' } }),
      'label must show the hunk number and total')
    assert(details.hl_mode == 'combine', 'labels must preserve the underlying diff highlight')
  end
end
local function assert_hunk_counter(buffer, current, total)
  local text = {}
  for _, mark in ipairs(header_marks(buffer)) do
    for _, chunk in ipairs(mark[4].virt_text) do text[#text + 1] = chunk[1] end
  end
  local label = '{ / } Hunks ' .. string.format('%' .. #tostring(total) .. 'd', current) .. '/' .. total
  assert(table.concat(text):find(label, 1, true), 'missing hunk counter ' .. label)
end
local function assert_full_header(win, mark)
  local details = mark[4]
  local chunks = details.virt_text
  local width = vim.api.nvim_win_get_width(win)
  local length, label_length = 0, 0
  for i, chunk in ipairs(chunks) do
    local size = vim.fn.strdisplaywidth(chunk[1])
    length = length + size
    if i > 1 and i < #chunks then label_length = label_length + size end
  end
  assert(details.virt_text_win_col == 0 and length == width,
    'virtual shortcuts must cover the entire window row')
  assert(chunks[1][1] == string.rep(' ', math.floor((width - label_length) / 2)),
    'labels must remain centered within the full-width header')
  assert(details.hl_mode == 'replace', 'header must replace underlying source highlighting')
end
local marks = vim.api.nvim_buf_get_extmarks(buf, namespaces['codeit-write-approval'], 0, -1, { details = true })
local header, colored = {}, {}
for _, mark in ipairs(header_marks(buf)) do
  assert(lines[mark[2] + 1] == '', 'shortcuts need an actual row so Neovim can draw them')
  for _, chunk in ipairs(mark[4].virt_text) do header[#header + 1] = chunk[1] end
  assert_full_header(win, mark)
end
for _, mark in ipairs(marks) do
  if mark[4].hl_group == 'DiffDelete' or mark[4].hl_group == 'DiffAdd' then
    colored[#colored + 1] = { lines[mark[2] + 1], mark[4].hl_group }
    assert(mark[4].hl_eol and mark[4].priority == 200)
  end
end
assert(vim.deep_equal(colored, { { 'local x = 1', 'DiffDelete' }, { 'local x = 2', 'DiffAdd' } }))
header = table.concat(header)
assert(header:find('1 Approve (Enter)', 1, true) and header:find('5 Review', 1, true)
  and header:find('Esc Reject', 1, true) and header:find('{ / } Hunks', 1, true))
assert(maps['{'] and maps['}'] and maps['5'] and maps['<Esc>'])
assert_hunk_labels(buf, { 'local x = 1' })
assert(not text:find('Hunk 1/1', 1, true), 'hunk labels must not be part of the preview text')
close('1', 'once')

win, buf, lines, maps, close = open('old first\nold second\n', 'new first\nnew second\n')
assert_hunk_labels(buf, { 'old first' })
close('3', 'reject')

win, buf, lines, maps, close = open('before\n', 'after\n')
assert(maps['<CR>'], 'Enter must be mapped in the write approval buffer')
close('<CR>', 'once')

win, buf, lines, maps, close = open('before\n', 'after\n', vim.fn.getcwd() .. '/lua/codeit/init.lua')
assert(title(win) == ' Review file edit: lua/codeit/init.lua ',
  'absolute paths should be displayed relative to the workspace, including directories')
close('3', 'reject')

local original, updated = {}, {}
for i = 1, 40 do original[i] = 'line ' .. i; updated[i] = original[i] end
updated[4], updated[35] = 'first change', 'second change'
win, buf, lines, maps, close = open(table.concat(original, '\n') .. '\n', table.concat(updated, '\n') .. '\n')
assert(table.concat(lines, '\n'):find('line 20', 1, true), 'the full file should include distant unchanged lines')
local hunks = {}
for i, line in ipairs(lines) do if line == 'line 4' or line == 'line 35' then hunks[#hunks + 1] = i end end
assert(#hunks == 2, 'both changed regions should appear in the file')
assert_hunk_labels(buf, { 'line 4', 'line 35' })
assert(vim.api.nvim_win_get_cursor(win)[1] == hunks[1], 'review should open at the first hunk')
local function scroll(topline)
  vim.api.nvim_win_call(win, function() vim.fn.winrestview({ topline = topline }) end)
  vim.api.nvim_exec_autocmds('WinScrolled', { pattern = tostring(win) })
  local actual = vim.fn.getwininfo(win)[1].topline
  assert(actual == topline, string.format('expected top line %d, got %d', topline, actual))
  local pinned = header_marks(buf)
  assert(#pinned > 0 and pinned[1][2] == topline - 1, 'shortcuts must follow the top visible line')
  for i, mark in ipairs(pinned) do
    assert(mark[2] == topline + i - 2, 'shortcut rows must stay together')
    assert_full_header(win, mark)
  end
  return #pinned
end
local header_count = scroll(1)
assert(scroll(10) == header_count and scroll(20) == header_count and scroll(5) == header_count,
  'scrolling must move rather than duplicate shortcuts')
assert(#vim.api.nvim_buf_get_extmarks(buf, namespaces['codeit-write-approval'], 0, -1, {}) == 4,
  'scrolling must preserve change highlights')
maps['}'](); assert(vim.api.nvim_win_get_cursor(win)[1] == hunks[2])
maps['}'](); assert(vim.api.nvim_win_get_cursor(win)[1] == hunks[1])
maps['{'](); assert(vim.api.nvim_win_get_cursor(win)[1] == hunks[2])
assert_hunk_labels(buf, { 'line 4', 'line 35' })
close('5', 'review')

-- Opening and navigation keep six lines above distant hunks and immediately repin the header.
original, updated = {}, {}
for i = 1, 200 do original[i] = 'line ' .. i; updated[i] = original[i] end
updated[60], updated[140] = 'first centered change', 'second centered change'
win, buf, lines, maps, close = open(table.concat(original, '\n') .. '\n', table.concat(updated, '\n') .. '\n')
hunks = {}
for i, line in ipairs(lines) do
  if line == 'line 60' or line == 'line 140' then hunks[#hunks + 1] = i end
end
local function assert_positioned(line)
  assert(vim.api.nvim_win_get_cursor(win)[1] == line)
  local top = vim.fn.getwininfo(win)[1].topline
  local context = math.min(6, vim.api.nvim_win_get_height(win) - 1)
  assert(top == math.max(1, line - context), 'selected hunk should have six lines above it when possible')
  local pinned = header_marks(buf)
  assert(#pinned > 0 and pinned[1][2] == top - 1, 'positioning must immediately repin the header')
  for _, mark in ipairs(pinned) do assert_full_header(win, mark) end
end
assert_hunk_counter(buf, 1, 2)
assert_positioned(hunks[1])
maps['}'](); assert_positioned(hunks[2]); assert_hunk_counter(buf, 2, 2)
maps['}'](); assert_positioned(hunks[1]); assert_hunk_counter(buf, 1, 2)
maps['{'](); assert_positioned(hunks[2]); assert_hunk_counter(buf, 2, 2)
maps['{'](); assert_positioned(hunks[1]); assert_hunk_counter(buf, 1, 2)
vim.api.nvim_win_set_cursor(win, { hunks[2] + 1, 0 })
vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
assert_hunk_counter(buf, 2, 2)
close('3', 'reject')

original, updated = {}, {}
for i = 1, 200 do original[i] = 'line ' .. i; updated[i] = original[i] end
for i = 1, 20 do updated[i * 10] = 'change ' .. i end
win, buf, lines, maps, close = open(table.concat(original, '\n') .. '\n', table.concat(updated, '\n') .. '\n')
assert_hunk_counter(buf, 1, 20)
maps['}'](); maps['}']()
assert_hunk_counter(buf, 3, 20)
local first_lines = {}
for i = 1, 20 do first_lines[i] = 'line ' .. i * 10 end
assert_hunk_labels(buf, first_lines)
for _, mark in ipairs(header_marks(buf)) do assert_full_header(win, mark) end
close('3', 'reject')

win, buf, lines, maps, close = open('start\nkeep\nremove\nend\n', 'start\n+literal\nkeep\nend\n')
local body = table.concat(lines, '\n')
assert(body:find('start\n+literal\nkeep\nremove\nend', 1, true), 'preserve real source text and position both changes')
local change_marks = vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_get_namespaces()['codeit-write-approval'],
  0, -1, { details = true })
local groups = {}
for _, mark in ipairs(change_marks) do
  if mark[4].hl_group == 'DiffAdd' or mark[4].hl_group == 'DiffDelete' then
    groups[lines[mark[2] + 1]] = mark[4].hl_group
  end
end
assert(groups['+literal'] == 'DiffAdd' and groups.remove == 'DiffDelete')
assert_hunk_labels(buf, { '+literal', 'remove' })
close('3', 'reject')

win, buf, lines, maps, close = open('', 'hello\n', 'new.txt')
assert_hunk_labels(buf, { 'hello' })
assert(table.concat(lines, '\n'):find('hello', 1, true) and not table.concat(lines, '\n'):find('/dev/null', 1, true))
close('<Esc>', nil)
win, buf, lines, maps, close = open('goodbye\n', '', 'removed.txt')
assert_hunk_labels(buf, { 'goodbye' })
assert(table.concat(lines, '\n'):find('goodbye', 1, true) and not table.concat(lines, '\n'):find('/dev/null', 1, true))
close('3', 'reject')
win, buf, lines, maps, close = open('same\n', 'same\n')
assert(table.concat(lines, '\n'):find('same', 1, true))
assert(vim.api.nvim_win_get_cursor(win)[1] == 1, 'unchanged previews should open at the top')
assert_hunk_counter(buf, 0, 0)
assert_hunk_labels(buf, {})
maps['}'](); assert(vim.api.nvim_win_get_cursor(win)[1] == 1)
close('2', 'always')
win, buf, lines, maps, close = open('disk\n', 'all buffer changes\n', 'save.txt',
  'SAVE ALL BUFFER CHANGES (including the user\'s edits)')
local pinned = header_marks(buf)
local warning_text = {}
for _, chunk in ipairs(pinned[1][4].virt_text) do warning_text[#warning_text + 1] = chunk[1] end
assert(table.concat(warning_text):find('SAVE ALL BUFFER CHANGES', 1, true), 'saving must show a pinned safety warning')
assert(not table.concat(warning_text):find('1 Approve', 1, true), 'warning must have its own row')
close('<CR>', 'once')
local dismissed = 0
popup.show({ path = 'example.lua', before = 'same\n', after = 'same\n' }, options, function(choice)
  assert(choice == nil)
  dismissed = dismissed + 1
end)
vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)
assert(vim.wait(1000, function() return dismissed == 1 end))
print('codeit write approval tests passed')
