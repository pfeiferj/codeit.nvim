vim.opt.runtimepath:prepend(vim.fn.getcwd())
local popup = require('codeit.write_approval')
local options = {
  { key = '1', id = 'once', label = 'Approve once' },
  { key = '2', id = 'always', label = 'Always approve exact call' },
  { key = '3', id = 'reject', label = 'Reject' },
  { key = '4', id = 'cancel', label = 'Cancel' },
  { key = '5', id = 'review', label = 'Ask reviewer' },
}
local function open(before, after, path)
  local calls, result = 0, nil
  local previous = vim.api.nvim_get_current_win()
  popup.show({ path = path or 'example.lua', before = before, after = after }, options, function(choice)
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

local win, buf, lines, maps, close = open('local x = 1\nprint(x)\n', 'local x = 2\nprint(x)\n')
assert(vim.bo[buf].filetype == 'lua', 'the preview should use the source filetype')
local text = table.concat(lines, '\n')
assert(not text:find('Approve once', 1, true), 'options must be virtual')
assert(text:find('local x = 1\nlocal x = 2\nprint(x)', 1, true), 'show old and new text in the full file')
assert(not text:find('--- example.lua', 1, true) and not text:find('@@', 1, true), 'no patch metadata')
local namespaces = vim.api.nvim_get_namespaces()
local function header_marks(buffer)
  return vim.api.nvim_buf_get_extmarks(buffer, namespaces['codeit-write-approval-header'], 0, -1, { details = true })
end
local marks = vim.api.nvim_buf_get_extmarks(buf, namespaces['codeit-write-approval'], 0, -1, { details = true })
local header, colored = {}, {}
for _, mark in ipairs(header_marks(buf)) do
  assert(lines[mark[2] + 1] == '', 'shortcuts need an actual row so Neovim can draw them')
  local length = 0
  for _, chunk in ipairs(mark[4].virt_text) do
    header[#header + 1] = chunk[1]
    length = length + vim.fn.strdisplaywidth(chunk[1])
  end
  assert(mark[4].virt_text_win_col == math.floor((vim.api.nvim_win_get_width(win) - length) / 2),
    'center each row of shortcuts')
end
for _, mark in ipairs(marks) do
  if mark[4].hl_group == 'DiffDelete' or mark[4].hl_group == 'DiffAdd' then
    colored[#colored + 1] = { lines[mark[2] + 1], mark[4].hl_group }
    assert(mark[4].hl_eol and mark[4].priority == 200)
  end
end
assert(vim.deep_equal(colored, { { 'local x = 1', 'DiffDelete' }, { 'local x = 2', 'DiffAdd' } }))
header = table.concat(header)
assert(header:find('1 Approve', 1, true) and header:find('5 Review', 1, true)
  and header:find('Esc Reject', 1, true) and header:find('{ / } Hunks', 1, true))
assert(maps['{'] and maps['}'] and maps['5'] and maps['<Esc>'])
close('1', 'once')

local original, updated = {}, {}
for i = 1, 40 do original[i] = 'line ' .. i; updated[i] = original[i] end
updated[4], updated[35] = 'first change', 'second change'
win, buf, lines, maps, close = open(table.concat(original, '\n') .. '\n', table.concat(updated, '\n') .. '\n')
assert(table.concat(lines, '\n'):find('line 20', 1, true), 'the full file should include distant unchanged lines')
local hunks = {}
for i, line in ipairs(lines) do if line == 'line 4' or line == 'line 35' then hunks[#hunks + 1] = i end end
assert(#hunks == 2, 'both changed regions should appear in the file')
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
    local length = 0
    for _, chunk in ipairs(mark[4].virt_text) do length = length + vim.fn.strdisplaywidth(chunk[1]) end
    assert(mark[4].virt_text_win_col == math.floor((vim.api.nvim_win_get_width(win) - length) / 2),
      'scrolled shortcuts must remain centered')
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
close('5', 'review')

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
close('3', 'reject')

win, buf, lines, maps, close = open('', 'hello\n', 'new.txt')
assert(table.concat(lines, '\n'):find('hello', 1, true) and not table.concat(lines, '\n'):find('/dev/null', 1, true))
close('<Esc>', nil)
win, buf, lines, maps, close = open('goodbye\n', '', 'removed.txt')
assert(table.concat(lines, '\n'):find('goodbye', 1, true) and not table.concat(lines, '\n'):find('/dev/null', 1, true))
close('3', 'reject')
win, buf, lines, maps, close = open('same\n', 'same\n')
assert(table.concat(lines, '\n'):find('same', 1, true))
assert(vim.api.nvim_win_get_cursor(win)[1] == 1, 'unchanged previews should open at the top')
maps['}'](); assert(vim.api.nvim_win_get_cursor(win)[1] == 1)
close('2', 'always')
local dismissed = 0
popup.show({ path = 'example.lua', before = 'same\n', after = 'same\n' }, options, function(choice)
  assert(choice == nil)
  dismissed = dismissed + 1
end)
vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)
assert(vim.wait(1000, function() return dismissed == 1 end))
print('codeit write approval tests passed')
