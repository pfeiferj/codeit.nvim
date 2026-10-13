vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.columns = 160 -- Leave enough room to test the default sidebar width.
local ui = require('codeit.ui')
local messages = {}
for i = 1, 50 do messages[i] = { role = 'user', content = 'message ' .. i } end
local sent
ui.open(function() sent = ui.take_input() end, ui.close)
local chat = vim.fn.bufnr('codeit://chat')
local win = vim.fn.bufwinid(chat)
assert(vim.api.nvim_win_get_width(win) == 80, 'chat sidebar should default to 80 columns')

local managed = require('codeit.ui.managed_tab')
local file_win = managed.windows()[1]
for _, width in ipairs({ 80, 60 }) do
  vim.api.nvim_win_set_width(win, width)
  for _, direction in ipairs({ 'vertical', 'horizontal' }) do
    local split = managed.split(file_win, direction)
    local height = vim.api.nvim_win_get_height(win)
    vim.api.nvim_win_close(split, true)
    assert(vim.api.nvim_win_get_width(win) == width,
      'closing a file split should preserve the current chat width')
    assert(vim.api.nvim_win_get_height(win) == height,
      'closing a file split should preserve the chat height')
    assert(vim.api.nvim_win_get_width(file_win) == vim.o.columns - width - 1,
      'the remaining file window should fill the space beside chat')
  end
end
vim.api.nvim_win_set_width(win, 80)
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(chat, 0, -1, false), { '## Message', '', '' }),
  'new chats should have a blank line between the heading and draft')
assert(vim.fn.bufnr('codeit://input') == -1, 'chat must have no separate input buffer')
assert(#vim.api.nvim_tabpage_list_wins(0) == 2, 'Codeit tab must use only one sidebar window')
assert(vim.bo[chat].filetype == 'codeit' and vim.bo[chat].syntax == 'codeit')
assert(vim.b[chat].current_syntax == 'codeit', 'Codeit syntax should be loaded')
assert(vim.wo[win].wrap and vim.wo[win].linebreak, 'sidebar prose should wrap at word boundaries')
local ns = vim.api.nvim_get_namespaces().codeit_chat_ui
assert(ns)

local function turn_key(key)
  vim.cmd('normal ' .. key)
  return vim.api.nvim_win_get_cursor(0)[1]
end
ui.render({}, 'Ready', 'test', 'test')
local empty_cursor = vim.api.nvim_win_get_cursor(win)
turn_key('{')
turn_key('}')
assert(vim.deep_equal(vim.api.nvim_win_get_cursor(win), empty_cursor), 'empty chats should not move')
local turn_messages = {
  { role = 'user', content = 'First request\n**You**' },
  { role = 'assistant', content = 'First response' },
  { role = 'tool', content = '**You**\nTool result' },
  { role = 'user', content = 'Second request' },
  { role = 'assistant', content = 'Second response' },
  { role = 'user', content = 'Third request' },
}
local function turn_rows()
  local rows = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(chat, ns, 0, -1, { details = true })) do
    if mark[4].hl_group == 'CodeitUser' then rows[#rows + 1] = mark[2] + 1 end
  end
  return rows
end
ui.render(turn_messages, 'Ready', 'test', 'test')
local rows = turn_rows()
vim.api.nvim_win_set_cursor(win, { 1, 0 })
assert(turn_key('}') == rows[1])
assert(turn_key('{') == rows[1], 'previous turn should not wrap')
assert(turn_key('}') == rows[2], 'navigation should skip assistant, tool, and fake speaker labels')
vim.api.nvim_win_set_cursor(win, { rows[2] + 2, 3 })
assert(turn_key('{') == rows[2], 'previous from inside a turn should go to its start')
assert(turn_key('}') == rows[3])
assert(turn_key('}') == rows[3], 'next turn should not wrap')
vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(chat), 0 })
assert(turn_key('{') == rows[3], 'previous from the draft should go to the latest turn')
assert(turn_key('2{') == rows[1], 'navigation should support counts')
assert(turn_key('9}') == rows[3], 'large counts should stop at the last turn')
ui.render(turn_messages, 'Working', 'test', 'test', 'Usage changed')
rows = turn_rows()
vim.api.nvim_win_set_cursor(win, { 1, 0 })
assert(turn_key('}') == rows[1], 'turn positions should track renders and header changes')
ui.toggle_popup()
assert(turn_key('}') == rows[2], 'interactive popup should share turn navigation')
ui.toggle_popup()
for _, map in ipairs(vim.api.nvim_buf_get_keymap(chat, 'i')) do
  assert(map.lhs ~= '{' and map.lhs ~= '}', 'turn mappings should be normal-mode only')
end

local function marks()
  return vim.api.nvim_buf_get_extmarks(chat, ns, 0, -1, { details = true })
end

local function hint()
  for _, mark in ipairs(marks()) do
    if mark[4].virt_lines then return mark[4].virt_lines[1][1][1] end
  end
  error('missing draft hint')
end

local function hint_lines()
  local lines, count = nil, 0
  for _, mark in ipairs(marks()) do
    if mark[4].virt_lines then
      lines, count = mark[4].virt_lines, count + 1
    end
  end
  assert(count == 1, 'refreshing the hint must not accumulate virtual lines')
  local text = {}
  for _, line in ipairs(lines) do
    assert(line[1][2] == 'Comment')
    text[#text + 1] = line[1][1]
  end
  return text
end

local function scroll(topline)
  vim.api.nvim_win_call(win, function() vim.fn.winrestview({ topline = topline }) end)
  vim.api.nvim_exec_autocmds('WinScrolled', { pattern = tostring(win) })
  local actual = vim.fn.getwininfo(win)[1].topline
  assert(actual == topline, string.format('expected top line %d, got %d', topline, actual))
end

ui.render(messages, 'Ready', 'openrouter', 'model-a', 'Cost: $0.001000 | In: 100 | Out: 20 | Context: 120')
local rendered = vim.api.nvim_buf_get_lines(chat, 0, 5, false)
assert(rendered[1]:match('^# Codeit') and rendered[2]:match('^> Cost:'))
assert(rendered[4] == '---' and rendered[5] == '')
assert(vim.api.nvim_buf_get_lines(chat, 5, 7, false)[1] == '**You**'
  and vim.api.nvim_buf_get_lines(chat, 5, 7, false)[2] == '',
  'speaker labels should be distinct from headings and separated from content')
vim.api.nvim_win_call(win, function()
  assert(vim.fn.synIDattr(vim.fn.synID(1, 1, true), 'name') ~= '',
    'chat heading should have active Markdown highlighting')
end)
local usage = 'Cost: $0.001000 | In: 100 | Out: 20 | Context: 120'
for _, topline in ipairs({ 1, 2, 3, 10, 20, 19, 18 }) do
  scroll(topline)
  assert(vim.wo[win].winbar == '%#WinBar#' .. usage, 'usage should remain outside the transcript')
  for _, mark in ipairs(marks()) do
    assert(not mark[4].virt_text, 'no usage overlay may obscure transcript text')
  end
end
ui.render(messages, 'Ready', 'copilot', 'model-b', nil)
assert(vim.wo[win].winbar == '', 'providers without usage must not display a usage header')
scroll(1)
assert(hint() == 'Ready · Ctrl-S: send · / commands',
  'ready hint should show only a short status and shortcuts')
assert(not vim.tbl_contains(vim.api.nvim_buf_get_lines(chat, 0, -1, false), '* Ready'),
  'status should not be a transcript line')
assert(not vim.tbl_contains(ui.chat_lines(), '* Ready'),
  'status should not be included in read-only transcripts')
for _, mark in ipairs(marks()) do
  if mark[4].virt_lines then
    assert(vim.api.nvim_buf_get_lines(chat, mark[2], mark[2] + 1, false)[1] == '## Message',
      'status and send instructions should be anchored below the message heading')
    assert(not mark[4].virt_lines_above, 'draft information should appear below the heading')
  end
end

-- Thinking dots advance independently of transcript renders and reserve three columns.
do
  local animated = ui.new({ floating = true, name = 'codeit://thinking-test', slash_commands = false })
  local defer, timers = vim.defer_fn, {}
  vim.defer_fn = function(callback, delay)
    assert(delay == 1000, 'thinking dots should tick once per second')
    timers[#timers + 1] = callback
  end
  local ok, err = pcall(function()
    local animation_win, animation_buf = animated.open(function() end, function() end)
    local function animation_hint()
      local text, count = nil, 0
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(animation_buf, ns, 0, -1, { details = true })) do
        if mark[4].virt_lines then
          text, count = mark[4].virt_lines[1][1][1], count + 1
        end
      end
      assert(count == 1, 'animation should update a single hint')
      return text
    end
    local function check_dots(dots)
      assert(animation_hint() == 'Thinking' .. string.rep('.', dots) .. string.rep(' ', 3 - dots)
        .. ' · Ctrl-S: send', 'dot padding must keep subsequent hints aligned')
    end
    animated.render({}, 'Thinking', 'test', 'test')
    check_dots(0)
    local content = vim.api.nvim_buf_get_lines(animation_buf, 0, -1, false)
    local cursor = vim.api.nvim_win_get_cursor(animation_win)
    for tick = 1, 4 do
      assert(#timers == 1, 'rerenders must not start additional animation loops')
      table.remove(timers, 1)()
      check_dots(tick % 4)
      if tick == 1 then
        animated.render({}, 'Thinking', 'test', 'test')
        check_dots(1)
      end
      assert(vim.deep_equal(content, vim.api.nvim_buf_get_lines(animation_buf, 0, -1, false)),
        'animation must not rewrite the transcript or draft')
      assert(vim.deep_equal(cursor, vim.api.nvim_win_get_cursor(animation_win)),
        'animation must not move the cursor')
    end
    local stale = table.remove(timers, 1)
    animated.render({}, 'Waiting', 'test', 'test')
    assert(animation_hint() == 'Waiting · Ctrl-S: send')
    animated.render({}, 'Thinking', 'test', 'test', nil, nil, false)
    assert(animation_hint() == 'Thinking   ', 'padding must survive even without following shortcuts')
    stale()
    assert(#timers == 1 and animation_hint() == 'Thinking   ', 'old callbacks must not advance a new animation')
    stale = table.remove(timers, 1)
    animated.close()
    stale()
    assert(#timers == 0, 'closing the chat must stop the animation loop')
    animation_win, animation_buf = animated.open(function() end, function() end)
    assert(animation_hint() == 'Thinking   ', 'reopening should start with zero dots')
    assert(#timers == 1)
  end)
  animated.destroy()
  vim.defer_fn = defer
  assert(ok, err)
end

-- Waiting counts from the last agent event, including the Thinking debounce.
do
  local waiting = ui.new({ floating = true, name = 'codeit://waiting-test', slash_commands = false })
  local defer, hrtime, timers, now = vim.defer_fn, vim.uv.hrtime, {}, 120
  vim.uv.hrtime = function() return now * 1e9 end
  vim.defer_fn = function(callback, delay)
    assert(delay == 1000, 'waiting elapsed time should refresh once per second')
    timers[#timers + 1] = callback
  end
  local ok, err = pcall(function()
    local waiting_win, waiting_buf = waiting.open(function() end, function() end)
    local function waiting_hint()
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(waiting_buf, ns, 0, -1, { details = true })) do
        if mark[4].virt_lines then return mark[4].virt_lines[1][1][1] end
      end
      error('missing waiting hint')
    end
    waiting.render({}, 'Waiting', 'test', 'test', nil, nil, false, nil, now * 1e9)
    assert(waiting_hint() == 'Waiting ( 0s )', 'the initial request should start counting before any data arrives')
    now = 121
    table.remove(timers, 1)()
    assert(waiting_hint() == 'Waiting ( 1s )')
    local stale = table.remove(timers, 1)
    waiting.render({}, 'Thinking', 'test', 'test', nil, nil, false, nil, now * 1e9)
    stale()
    assert(#timers == 1, 'resumed activity must cancel the waiting counter loop')
    stale = table.remove(timers, 1)
    now = 131
    waiting.render({}, 'Waiting', 'test', 'test', nil, nil, false, nil, 121 * 1e9)
    assert(waiting_hint() == 'Waiting ( 10s )', 'Waiting must include time spent in Thinking')
    stale()
    assert(#timers == 1, 'transitioning to Waiting should leave only one active timer')
    local content = vim.api.nvim_buf_get_lines(waiting_buf, 0, -1, false)
    local cursor = vim.api.nvim_win_get_cursor(waiting_win)
    now = 144
    table.remove(timers, 1)()
    assert(waiting_hint() == 'Waiting ( 23s )', 'elapsed time must use the clock, not count refreshes')
    assert(vim.deep_equal(content, vim.api.nvim_buf_get_lines(waiting_buf, 0, -1, false)),
      'waiting counter ticks must not rewrite the transcript')
    assert(vim.deep_equal(cursor, vim.api.nvim_win_get_cursor(waiting_win)),
      'waiting counter ticks must not move the cursor')
    stale = table.remove(timers, 1)
    waiting.render({}, 'Ready', 'test', 'test')
    stale()
    assert(#timers == 0 and waiting_hint() == 'Ready · Ctrl-S: send',
      'completion must stop counter updates')
    waiting.render({}, 'Waiting', 'test', 'test', nil, nil, false, nil, 121 * 1e9)
    stale = table.remove(timers, 1)
    waiting.close()
    stale()
    assert(#timers == 0, 'closing the chat must stop waiting updates')
  end)
  waiting.destroy()
  vim.defer_fn, vim.uv.hrtime = defer, hrtime
  assert(ok, err)
end

local long_status = 'Working on 界面 é ' .. string.rep('界', 30) .. ' ' .. string.rep('x', 90)
local discovery = '/ commands'
local send_hint = 'Ctrl-S: send · ' .. discovery
local busy_hint = discovery
local function check_wrapped(expected, windows)
  local lines = hint_lines()
  assert(#lines > 1, 'long status should wrap into multiple virtual lines')
  for _, window in ipairs(windows) do
    local width = vim.api.nvim_win_get_width(window) - vim.fn.getwininfo(window)[1].textoff
    for _, line in ipairs(lines) do
      assert(vim.fn.strdisplaywidth(line) <= width, 'virtual status must fit the text area')
    end
  end
  assert(table.concat(lines):gsub('%s', '') == expected:gsub('%s', ''),
    'wrapping must preserve status and instructions, including Unicode and long words')
  return #lines
end
ui.render(messages, long_status, 'copilot', 'model-b')
local before_resize = vim.api.nvim_buf_get_lines(chat, 0, -1, false)
local before_cursor = vim.api.nvim_win_get_cursor(win)
vim.api.nvim_win_set_width(win, 24)
vim.api.nvim_exec_autocmds('WinResized', {})
local narrow_lines = check_wrapped(long_status .. ' · ' .. send_hint, { win })
vim.wo[win].number = true
vim.wo[win].foldcolumn = '2'
vim.api.nvim_exec_autocmds('WinResized', {})
check_wrapped(long_status .. ' · ' .. send_hint, { win })
vim.wo[win].number = false
vim.wo[win].foldcolumn = '0'
vim.api.nvim_win_set_width(win, 80)
vim.api.nvim_exec_autocmds('WinResized', {})
assert(check_wrapped(long_status .. ' · ' .. send_hint, { win }) < narrow_lines,
  'widening the window should reflow the hint')
vim.api.nvim_exec_autocmds('VimResized', {})
check_wrapped(long_status .. ' · ' .. send_hint, { win })
assert(vim.deep_equal(before_resize, vim.api.nvim_buf_get_lines(chat, 0, -1, false)),
  'reflow must not change the transcript or draft')
assert(vim.deep_equal(before_cursor, vim.api.nvim_win_get_cursor(win)),
  'reflow must not move the cursor')
ui.toggle_popup()
local hint_popup = vim.api.nvim_get_current_win()
check_wrapped(long_status .. ' · ' .. send_hint, { win, hint_popup })
vim.api.nvim_win_set_width(win, 30)
vim.api.nvim_exec_autocmds('WinResized', {})
check_wrapped(long_status .. ' · ' .. send_hint, { win, hint_popup })
ui.render(messages, long_status, 'copilot', 'model-b', nil, nil, false)
check_wrapped(long_status .. ' · ' .. busy_hint, { win, hint_popup })
ui.toggle_popup()
check_wrapped(long_status .. ' · ' .. busy_hint, { win })
vim.api.nvim_win_set_width(win, 80)
ui.render(messages, 'Ready', 'copilot', 'model-b')

local count = vim.api.nvim_buf_line_count(chat)
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(chat, count - 3, count, false), { '## Message', '', '' }),
  'rendered chats should have a blank line between the heading and draft')
vim.api.nvim_buf_set_lines(chat, count - 1, -1, false, { 'first line', 'second line' })
vim.api.nvim_win_set_cursor(win, { count + 1, 4 })
ui.render(messages, 'Waiting', 'copilot', 'model-b', nil, nil, false)
assert(vim.api.nvim_win_get_cursor(win)[2] == 4)
assert(vim.tbl_contains(vim.api.nvim_buf_get_lines(chat, 0, -1, false), '## Message'),
  'the draft heading should remain visible while sending is blocked')
assert(hint() == 'Waiting · / commands',
  'blocked hint should show a concise status without send or draft explanations')
assert(ui.peek_input() == 'first line\nsecond line', 'blocked sending must preserve the draft')
local function check_message_highlight(disabled)
  for _, mark in ipairs(marks()) do
    if mark[4].virt_lines then
      assert(mark[4].hl_group == (disabled and 'CodeitMessageDisabled' or nil),
        'message heading should be gray only while sending is blocked')
      assert(mark[4].end_col == #'## Message', 'highlight should cover only the message heading')
    end
  end
end
check_message_highlight(true)
assert(vim.api.nvim_get_hl(0, { name = 'CodeitMessageDisabled' }).fg
  == (vim.o.background == 'light' and 0x767676 or 0x808080),
  'disabled message highlight should default to gray')
ui.toggle_popup()
check_message_highlight(true)
ui.toggle_popup()
check_message_highlight(true)
ui.render(messages, 'Ready', 'copilot', 'model-b', nil, nil, true)
check_message_highlight(false)
assert(vim.api.nvim_win_get_cursor(win)[2] == 4)
assert(vim.api.nvim_buf_get_lines(chat, -3, -1, false)[1] == 'first line')
assert(ui.take_input() == 'first line\nsecond line')
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(chat, -4, -1, false), { '## Message', '', '' }),
  'sending should preserve the separator')
assert(ui.take_input() == nil, 'empty drafts should not send')
for _, status in ipairs({ '', false }) do
  ui.render(messages, status or nil, 'copilot', 'model-b')
  assert(hint():find('Ctrl-S: send', 1, true) == 1,
    'absent status should leave only the send instructions')
end
ui.render({
  { role = 'assistant', content = vim.NIL, tool_calls = {
    { id = 'call_hash_1', ['function'] = { name = 'read_file', arguments = '{"path":"src/main.lua","start_line":2}' } },
    { id = 'call_hash_2', ['function'] = { name = 'git_diff', arguments = '{}' } },
  } },
  { role = 'tool', tool_call_id = 'call_hash_2', content = 'diff' },
  { role = 'tool', tool_call_id = 'call_hash_1', content = 'file' },
  { role = 'tool', tool_call_id = 'unmatched', content = 'other' },
}, 'Ready', 'copilot', 'model-b', nil)
local transcript = table.concat(vim.api.nvim_buf_get_lines(chat, 0, -1, false), '\n')
assert(transcript:find('*Calling `read_file`…*\n\n```json\n{\n  "path": "src/main.lua",\n  "start_line": 2\n}\n```', 1, true),
  'tool inputs should be shown as readable JSON beneath each call')
assert(transcript:find('*Calling `git_diff`…*\n\n```json\n{}\n```', 1, true),
  'empty tool inputs should still be shown')
assert(transcript:find('**Tool: git_diff**\n\n```diff\ndiff\n```', 1, true))
assert(transcript:find('**Tool: read_file**\n\n```text\nfile\n```', 1, true))
assert(transcript:find('**Tool: unmatched**\n\n```text\nother\n```', 1, true), 'unmatched results retain their ID')
assert(not transcript:find('**Tool: call_hash_', 1, true), 'matched results should not show call hashes')

local input_call = { id = 'input_call', ['function'] = {
  name = 'edit_file', arguments = '{"path":"src/main.lua","edits":[{"old_text":"before","new_text":"after"}]}' },
}
local input_message = { role = 'assistant', tool_calls = { input_call,
  { ['function'] = { name = 'partial', arguments = '{"text":"```\nunfinished' } },
  { ['function'] = { name = 'missing' } },
  { ['function'] = { name = 'empty', arguments = '' } },
  {},
} }
local original_arguments = input_call['function'].arguments
ui.render({ input_message }, 'Working', 'copilot', 'model-b', nil)
local input_lines = vim.api.nvim_buf_get_lines(chat, 0, -1, false)
local input_text = table.concat(input_lines, '\n')
assert(input_text:find('*Calling `partial`…*\n\n````text\n{"text":"```\nunfinished\n````', 1, true),
  'partial inputs should remain literal and safely fenced')
assert(input_text:find('*Calling `missing`…*', 1, true))
assert(input_text:find('*Calling `empty`…*', 1, true))
assert(input_text:find('*Calling `unknown tool`…*', 1, true))
assert(input_call['function'].arguments == original_arguments, 'input formatting must not mutate messages')
assert(table.concat(ui.chat_lines(), '\n'):find('"new_text": "after"', 1, true),
  'read-only transcripts should include tool inputs')
local input_fold
for row, line in ipairs(input_lines) do
  if line == '*Calling `edit_file`…*' then input_fold = row; break end
end
vim.api.nvim_win_call(win, function()
  assert(vim.fn.foldclosed(input_fold) == input_fold - 2, 'activity should start collapsed')
  vim.cmd((input_fold - 2) .. 'foldopen')
  assert(vim.fn.foldclosed(input_fold) == -1, 'opening activity should reveal tool inputs')
  assert(vim.fn.foldlevel(input_fold) == 1, 'tool inputs should not have individual folds')
end)
ui.render({ input_message }, 'Working', 'copilot', 'model-b', nil)
assert(vim.fn.foldclosed(input_fold) == -1, 'expanded inputs should survive streamed renders')

local command_output = 'if true; then echo "$HOME"; fi'
local json_output = '{"enabled": true}'
ui.render({
  { role = 'assistant', tool_calls = {
    { id = 'command_call', ['function'] = { name = 'run_command', arguments = '{}' } },
  } },
  { role = 'tool', tool_call_id = 'command_call', content = command_output },
  { role = 'tool', name = 'read_file', content = json_output },
  { role = 'tool', name = 'list_buffers', content = '[]' },
  { role = 'tool', name = 'custom_tool', content = { { type = 'text', text = json_output } } },
  { role = 'tool', name = 'list_buffers', content = 'Error: unavailable' },
  { role = 'tool', name = 'custom_tool', content = '{invalid json}' },
  { role = 'tool', name = 'run_command', content = json_output },
}, 'Ready', 'copilot', 'model-b', nil)
local language_text = table.concat(vim.api.nvim_buf_get_lines(chat, 0, -1, false), '\n')
for _, expected in ipairs({
  '**Tool: run_command**\n\n```bash\n' .. command_output .. '\n```',
  '**Tool: read_file**\n\n```json\n' .. json_output .. '\n```',
  '**Tool: list_buffers**\n\n```json\n[]\n```',
  '**Tool: custom_tool**\n\n```json\n' .. json_output .. '\n```',
  '**Tool: list_buffers**\n\n```text\nError: unavailable\n```',
  '**Tool: custom_tool**\n\n```text\n{invalid json}\n```',
  '**Tool: run_command**\n\n```bash\n' .. json_output .. '\n```',
}) do
  assert(language_text:find(expected, 1, true), 'missing language-aware tool output: ' .. expected)
end
vim.wait(50, function() return false end)
vim.api.nvim_win_call(win, function()
  vim.cmd('syntax sync fromstart')
  for row, line in ipairs(vim.api.nvim_buf_get_lines(chat, 0, -1, false)) do
    if line == command_output then
      assert(vim.fn.synIDattr(vim.fn.synID(row, 1, true), 'name'):match('^sh'),
        'command output should use shell syntax highlighting')
    elseif line == json_output and row > 1
      and vim.api.nvim_buf_get_lines(chat, row - 2, row - 1, false)[1] == '```json' then
      assert(vim.fn.synIDattr(vim.fn.synID(row, 2, true), 'name'):match('^json'),
        'JSON tool output should use JSON syntax highlighting')
    end
  end
end)

-- Activity bodies must be inserted into folds that already exist in every chat view.
do
  local activity = {
    { role = 'user', content = 'Run the tools' },
    { role = 'assistant', reasoning_details = { { text = 'fold test reasoning\nsecond line' } },
      tool_calls = { { id = 'fold_test', ['function'] = {
        name = 'read_file', arguments = '{"path":"fold test input"}',
      } } } },
    { role = 'tool', tool_call_id = 'fold_test', content = 'fold test output\n' .. string.rep('wrapped ', 100) },
  }
  local results = { { after_message = 3, command = '/context', output = 'fold test command\nsecond line' } }
  ui.toggle_popup()
  local popup = vim.api.nvim_get_current_win()
  local before = {}
  for _, view in ipairs({ win, popup }) do
    vim.api.nvim_win_call(view, function()
      vim.api.nvim_win_set_cursor(view, { 1, 0 })
      vim.fn.winrestview({ topline = 1 })
      before[view] = vim.fn.winsaveview()
    end)
  end
  local set_lines, set_text = vim.api.nvim_buf_set_lines, vim.api.nvim_buf_set_text
  local text_height, cmd = vim.api.nvim_win_text_height, vim.cmd
  local writes, buffer_writes, refreshing, fold_resets = 0, 0, false, 0
  local window_count = #vim.api.nvim_list_wins()
  vim.cmd = setmetatable({}, { __index = cmd, __call = function(_, command)
    local current = vim.api.nvim_get_current_win()
    if current == win or current == popup then
      assert(not command:find('foldopen', 1, true),
        'fold-state capture must not temporarily open live activity sections')
      assert(not command:find('zE', 1, true),
        'live fold decoration must never delete and rebuild populated folds')
    end
    local resetting = (current == win or current == popup) and command:find('zX', 1, true)
    if resetting then
      fold_resets = fold_resets + 1
      assert(vim.wo[current].foldlevel == 0, 'fold recomputation must start closed, even after zR')
      assert(vim.o.foldopen == '', 'chat folds must not open automatically')
    end
    local result = cmd(command)
    if resetting then
      for row, level in pairs(vim.w[current].codeit_fold_levels) do
        if level == '>1' then
          assert(vim.fn.foldclosed(tonumber(row)) ~= -1,
            'recomputation must never briefly open activity before state restoration')
          local summary = vim.w[current].codeit_fold_summaries[row]
          assert(summary and summary.preview:find('Activity', 1, true),
            'safe summaries must exist before recomputation can request foldtext')
        end
      end
    end
    return result
  end })
  vim.api.nvim_win_text_height = function(target, range)
    assert(vim.api.nvim_win_get_config(target).hide,
      'activity height must be measured in an invisible window')
    assert(vim.wo[win].foldenable and vim.wo[popup].foldenable,
      'summary measurements must never disable live folds')
    return text_height(target, range)
  end
  local function check_activity_write(first, replacement)
    for offset, line in ipairs(replacement) do
      if line:find('fold test', 1, true) or line:find('wrapped ', 1, true)
        or line == '**Activity**' or line == '**Reasoning**'
        or line == '*Calling `read_file`…*' or line == '**Tool: read_file**'
        or line == '## Command: `/context`' then
        local row = first + offset
        for _, view in ipairs({ win, popup }) do
          vim.api.nvim_win_call(view, function()
            assert(vim.fn.foldlevel(row) == 1,
              'activity headings and bodies must have their folds before being written')
            assert(vim.fn.foldclosed(row) ~= -1,
              'activity must already be hidden in both sidebar and popup when written')
          end)
        end
      end
    end
  end
  vim.api.nvim_buf_set_lines = function(buf, first, last, strict, replacement)
    if buf == chat then
      buffer_writes = buffer_writes + 1
      check_activity_write(first, replacement)
    end
    local result = set_lines(buf, first, last, strict, replacement)
    if buf == chat then
      for row, line in ipairs(vim.api.nvim_buf_get_lines(chat, 0, -1, false)) do
        if line:find('fold test', 1, true) then
          for _, view in ipairs({ win, popup }) do
            vim.api.nvim_win_call(view, function()
              assert(vim.fn.foldclosed(row) ~= -1,
                'reserving rows must not expose existing hidden activity')
            end)
          end
        end
      end
    end
    return result
  end
  vim.api.nvim_buf_set_text = function(buf, first, col, last, end_col, replacement)
    if buf == chat then
      buffer_writes = buffer_writes + 1
      check_activity_write(first, replacement)
      if table.concat(replacement, '\n'):find('fold test', 1, true) then writes = writes + 1 end
    end
    local result = set_text(buf, first, col, last, end_col, replacement)
    if buf == chat then check_activity_write(first, replacement) end
    return result
  end
  local ok, err = pcall(function()
    ui.render(activity, 'Thinking', 'test', 'test', nil, results, false)
    assert(fold_resets == 2, 'each chat view must be recomputed only once per structural render')
    for _, view in ipairs({ win, popup }) do
      vim.api.nvim_win_call(view, function()
        vim.wo[view].foldlevel = 1
        for row, line in ipairs(vim.api.nvim_buf_get_lines(chat, 0, -1, false)) do
          if line == '**Activity**' then vim.cmd(row .. 'foldclose') end
        end
      end)
    end
    activity[3].content = activity[3].content .. '\nfold test growing output' .. string.rep('\nfold test extra row', 30)
    activity[2].reasoning_details[1].text = 'fold test revised reasoning\nsecond line\nthird line'
    activity[2].tool_calls[1]['function'].arguments = '{"path":"fold test revised input"}'
    ui.render(activity, 'Thinking', 'test', 'test', 'Changed billing', results, false)
    activity[3].content = 'fold test output\nfold test growing output'
    activity[1].content = 'Run the tools\nwith a longer prompt'
    ui.render(activity, 'Thinking', 'test', 'test', nil, results, false)
    table.insert(activity, 3, { role = 'tool', name = 'read_file', content = 'fold test inserted output' })
    results[1].after_message = 4
    ui.render(activity, 'Thinking', 'test', 'test', nil, results, false)
    table.remove(activity, 3)
    results[1].after_message = 3
    ui.render(activity, 'Thinking', 'test', 'test', nil, results, false)
    local unchanged_writes, unchanged_resets = buffer_writes, fold_resets
    ui.render(activity, 'Waiting', 'test', 'test', nil, results, false)
    assert(buffer_writes == unchanged_writes, 'status changes must leave the transcript buffer untouched')
    assert(fold_resets == unchanged_resets, 'status changes must not recompute existing folds')
    refreshing = true
    vim.api.nvim_exec_autocmds('WinResized', {})
    vim.api.nvim_exec_autocmds('VimResized', {})
    refreshing = false
  end)
  vim.api.nvim_buf_set_lines, vim.api.nvim_buf_set_text = set_lines, set_text
  vim.api.nvim_win_text_height, vim.cmd = text_height, cmd
  assert(ok, err)
  assert(#vim.api.nvim_list_wins() == window_count, 'fold probes must not leak windows')
  assert(vim.api.nvim_get_current_win() == popup, 'fold probes must not change the focused window')
  assert(writes >= 4, 'new and updated activity must be written after fold preparation')
  local text = table.concat(vim.api.nvim_buf_get_lines(chat, 0, -1, false), '\n')
  for _, body in ipairs({ 'fold test revised reasoning', 'fold test revised input', 'fold test output',
    'fold test command', 'fold test growing output' }) do
    assert(text:find(body, 1, true), 'fold staging must retain all activity content')
  end
  for _, view in ipairs({ win, popup }) do
    vim.api.nvim_win_call(view, function()
      local after = vim.fn.winsaveview()
      assert(after.topline == before[view].topline and after.lnum == before[view].lnum,
        'adding folded activity must preserve a scrolled-back viewport')
    end)
  end
  local section_row, reasoning_row
  for row, line in ipairs(vim.api.nvim_buf_get_lines(chat, 0, -1, false)) do
    if line == '**Activity**' then section_row = row end
    if line == '**Reasoning**' then reasoning_row = row end
  end
  vim.api.nvim_win_call(popup, function()
    vim.cmd(section_row .. 'foldopen')
  end)
  ui.render(activity, 'Thinking', 'test', 'test', nil, results, false)
  for _, view in ipairs({ win, popup }) do
    vim.api.nvim_win_call(view, function()
      assert(vim.fn.foldclosed(reasoning_row) == (view == popup and -1 or section_row),
        'activity must retain its independent per-window expansion state')
      if view == win then vim.cmd(section_row .. 'foldopen') end
      assert(vim.fn.foldclosed(reasoning_row) == -1 and vim.fn.foldlevel(reasoning_row) == 1,
        'opening activity must reveal reasoning without a child fold')
      vim.cmd(section_row .. 'foldclose')
    end)
  end
  ui.toggle_popup()
end

-- Interactive popups must also have their activity folds before they become visible.
do
  local open_win, set_config, cmd = vim.api.nvim_open_win, vim.api.nvim_win_set_config, vim.cmd
  local created_hidden, revealed = false, false
  vim.api.nvim_open_win = function(buf, enter, config)
    if buf == chat and config.title and config.title:find('Codeit chat', 1, true) then
      assert(config.hide and not enter, 'interactive popup must be created hidden and unfocused')
      created_hidden = true
    end
    return open_win(buf, enter, config)
  end
  vim.api.nvim_win_set_config = function(target, config)
    if config.hide == false and vim.api.nvim_win_get_buf(target) == chat then
      vim.api.nvim_win_call(target, function()
        for row, line in ipairs(vim.api.nvim_buf_get_lines(chat, 0, -1, false)) do
          if line:find('fold test', 1, true) then
            assert(vim.fn.foldclosed(row) ~= -1, 'interactive popup must contain folded activity before reveal')
          end
        end
      end)
      revealed = true
    end
    return set_config(target, config)
  end
  vim.cmd = setmetatable({}, { __index = cmd, __call = function(_, command)
    assert(not command:find('zE', 1, true), 'popup switching must never delete live folds')
    return cmd(command)
  end })
  local ok, err = pcall(function()
    ui.toggle_popup()
    ui.toggle_popup()
  end)
  vim.api.nvim_open_win, vim.api.nvim_win_set_config, vim.cmd = open_win, set_config, cmd
  assert(ok, err)
  assert(created_hidden and revealed, 'interactive popup should be prepared before reveal')
end

-- Tool output is literal display data, even when it contains unclosed Markdown.
local output = table.concat({
  '# Heading inside output', '```lua', 'local value = 1', '```',
  '````', '   `````', '~~~', '<script>', '**unfinished emphasis', '[unfinished link',
}, '\n')
local tool_message = { role = 'tool', name = 'read_file', content = output }
ui.render({
  { role = 'user', content = '**User formatting**' }, tool_message,
  { role = 'tool', name = 'parts', content = { { type = 'text', text = 'part one' },
    { type = 'text', text = 'part two' } } },
  { role = 'assistant', content = '# After tool output\n**Assistant formatting**' },
}, 'Ready', 'openrouter', 'model-a', nil)
local safe_lines = vim.api.nvim_buf_get_lines(chat, 0, -1, false)
local safe_text = table.concat(safe_lines, '\n')
assert(safe_text:find('**Tool: read_file**\n\n``````text\n' .. output .. '\n``````\n', 1, true),
  'outer fence must be longer than every backtick run in the tool output')
assert(safe_text:find('**Tool: parts**\n\n```text\npart one\npart two\n```', 1, true),
  'text-part tool results should also be fenced')
assert(safe_text:find('**You**\n\n**User formatting**', 1, true))
assert(safe_text:find('**Assistant**\n\n# After tool output\n**Assistant formatting**', 1, true),
  'assistant Markdown should remain unfenced')
assert(tool_message.content == output, 'display fencing must not mutate the tool result')
vim.api.nvim_win_call(win, function()
  vim.cmd('syntax sync fromstart')
  local function syntax_at(text)
    for row, line in ipairs(safe_lines) do
      if line == text then return vim.fn.synIDattr(vim.fn.synID(row, 1, true), 'name') end
    end
    error('missing line ' .. text)
  end
  assert(syntax_at('# Heading inside output') == 'CodeitCodeBlock', 'tool Markdown must stay literal')
  assert(syntax_at('   `````') == 'CodeitCodeBlock', 'embedded fences must not close the wrapper')
  assert(syntax_at('**unfinished emphasis') == 'CodeitCodeBlock')
  assert(syntax_at('# After tool output') == syntax_at('# Codeit (openrouter: model-a)'),
    'Markdown heading highlighting must recover after the tool block')
  assert(syntax_at('## Message') == 'CodeitHeading',
    'draft heading must remain outside code blocks')
end)

local fold_start
for row, line in ipairs(safe_lines) do
  if line == '**Tool: read_file**' then fold_start = row; break end
end
assert(fold_start)
vim.api.nvim_win_call(win, function()
  assert(vim.fn.foldclosed(fold_start) == fold_start - 2, 'activity should start collapsed')
  local preview = vim.fn.foldtextresult(fold_start - 2)
  assert(preview:find('Activity', 1, true) and preview:find('lines · za: expand', 1, true))
  vim.api.nvim_win_set_cursor(win, { fold_start - 2, 0 })
  vim.cmd('normal! za')
  assert(vim.fn.foldclosed(fold_start) == -1, 'za should reveal the full tool result')
end)
local updated_messages = {
  { role = 'user', content = '**User formatting**' }, tool_message,
  { role = 'assistant', content = 'Streaming update' },
}
ui.render(updated_messages, 'Working', 'openrouter', 'model-a', 'Cache: 50%', nil, false)
for row, line in ipairs(vim.api.nvim_buf_get_lines(chat, 0, -1, false)) do
  if line == '**Tool: read_file**' then fold_start = row; break end
end
assert(vim.fn.foldlevel(fold_start) == 1, 'activity folds must track header layout changes')
assert(vim.wo[win].winbar == '%#WinBar#Cache: 50%%', 'billing percentages must be escaped in the winbar')
assert(vim.fn.foldclosed(fold_start) == -1, 'expanded tool output must survive streamed renders')
ui.toggle_popup()
local folded_popup = vim.api.nvim_get_current_win()
assert(vim.fn.foldclosed(fold_start) == -1, 'expanded state must carry into the popup')
assert(vim.wo[folded_popup].winbar == '%#WinBar#Cache: 50%%')
vim.api.nvim_win_set_cursor(folded_popup, { fold_start, 0 })
vim.cmd('normal! za')
ui.toggle_popup()
assert(vim.fn.foldclosed(fold_start) == fold_start - 2, 'popup activity changes must carry back to the sidebar')
assert(ui.peek_input() == nil, 'fold controls must not change the draft')

local command_output = table.concat({ 'summary', 'one', 'two', 'three', 'four', 'five', 'six' }, '\n')
ui.render({}, 'Ready', 'copilot', 'model-b', nil,
  { { after_message = 0, command = '/contextFull', output = command_output } })
local function rendered_row(text)
  for row, line in ipairs(vim.api.nvim_buf_get_lines(chat, 0, -1, false)) do
    if line == text then return row end
  end
  error('missing line ' .. text)
end
local command_row = rendered_row('## Command: `/contextFull`')
assert(vim.fn.foldclosed(command_row) == command_row - 2, 'command activity should start collapsed')
vim.cmd((command_row - 2) .. 'foldopen')
assert(vim.fn.foldclosed(command_row) == -1, 'opening activity should reveal commands')
assert(table.concat(ui.chat_lines(), '\n'):find(command_output, 1, true),
  'folding must retain full output in read-only transcripts')

-- Short and wrapped items share the activity fold, regardless of window width.
local text_width = vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff
local wrapped_message = { role = 'tool', name = 'wrapped', content = string.rep('x', text_width * 6) }
ui.render({ wrapped_message }, 'Ready', 'test', 'test')
local wrapped_start = rendered_row('**Tool: wrapped**')
assert(vim.fn.foldlevel(wrapped_start) == 1)
assert(vim.fn.foldclosed(wrapped_start) == wrapped_start - 2)
wrapped_message.content = wrapped_message.content .. 'x'
ui.render({ wrapped_message }, 'Working', 'test', 'test')
assert(vim.fn.foldclosed(wrapped_start) == wrapped_start - 2, 'collapsed activity must survive renders')
vim.api.nvim_win_set_cursor(win, { wrapped_start, 0 })
vim.cmd('normal! za')
ui.render({ wrapped_message }, 'Working', 'test', 'test')
assert(vim.fn.foldclosed(wrapped_start) == -1, 'expanded wrapped output must survive renders')
ui.toggle_popup()
assert(vim.fn.foldlevel(wrapped_start) == 1 and vim.fn.foldclosed(wrapped_start) == -1,
  'wider popups should retain activity folds and their state')
ui.toggle_popup()
assert(vim.fn.foldclosed(wrapped_start) == -1)
vim.api.nvim_win_set_cursor(win, { wrapped_start, 0 })
vim.cmd('normal! za')
local wide_summary = vim.fn.foldtextresult(wrapped_start - 2)
vim.api.nvim_win_set_width(win, 40)
vim.api.nvim_exec_autocmds('WinResized', {})
local narrow_summary = vim.fn.foldtextresult(wrapped_start - 2)
assert(narrow_summary ~= wide_summary, 'fold summaries should reflect wrapped screen height')
vim.api.nvim_win_set_width(win, 120)
vim.api.nvim_exec_autocmds('WinResized', {})
assert(vim.fn.foldlevel(wrapped_start) == 1 and vim.fn.foldclosed(wrapped_start) == wrapped_start - 2,
  'resizing must retain activity folds and their state')
vim.api.nvim_win_set_width(win, 80)
vim.api.nvim_exec_autocmds('WinResized', {})
local wrapped_command = string.rep('x', text_width * 6 + 1)
ui.render({}, 'Ready', 'test', 'test', nil,
  { { after_message = 0, command = '/contextFull', output = wrapped_command } })
command_row = rendered_row('## Command: `/contextFull`')
assert(vim.fn.foldclosed(command_row) == command_row - 2)
vim.api.nvim_win_set_cursor(win, { command_row, 0 })
vim.cmd('normal! za')
assert(vim.fn.foldclosed(command_row) == -1, 'single-line activity must remain expandable')

local groups = {}
ui.render(updated_messages, 'Ready', 'copilot', 'model-b', nil)
for _, mark in ipairs(marks()) do
  if mark[4].hl_group then groups[mark[4].hl_group] = true end
end
assert(groups.CodeitUser and groups.CodeitAssistant and groups.CodeitTool,
  'speaker roles should have distinct highlight groups')
ui.close()
assert(#marks() == 0)
ui.open(function() sent = ui.take_input() end, ui.close)
assert(ui.is_open() and vim.fn.bufwinid(chat) ~= -1)
local last = vim.api.nvim_buf_line_count(chat)
vim.api.nvim_buf_set_lines(chat, last - 1, -1, false, { 'draft after reopen' })
ui.render(messages, 'Ready', 'copilot', 'model-b', nil)
assert(ui.take_input() == 'draft after reopen')
local fresh = vim.api.nvim_buf_line_count(chat)
vim.api.nvim_buf_set_lines(chat, fresh - 1, -1, false, { 'sent by mapping' })
vim.api.nvim_win_set_cursor(vim.fn.bufwinid(chat), { fresh, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'x', false)
assert(sent == 'sent by mapping', 'normal Enter sends the draft')

-- The interactive popup shares the sidebar buffer and all message mappings.
local function press(key, mode)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(chat, mode or 'n')) do
    if map.lhs:lower() == key:lower() then map.callback(); return end
  end
  error('missing mapping ' .. key)
end
local sidebar = vim.api.nvim_get_current_win()
local row = vim.api.nvim_buf_line_count(chat)
vim.api.nvim_buf_set_lines(chat, row - 1, -1, false, { 'popup draft' })
vim.api.nvim_win_set_cursor(sidebar, { row, 3 })
press('<C-g>')
local popup = vim.api.nvim_get_current_win()
assert(popup ~= sidebar and ui.is_open())
assert(vim.api.nvim_win_get_buf(popup) == chat and vim.bo[chat].modifiable)
assert(vim.api.nvim_win_get_config(popup).relative == 'editor')
assert(vim.api.nvim_win_get_width(popup) == vim.o.columns - 4)
assert(vim.api.nvim_win_get_height(popup) == vim.o.lines - 6)
assert(vim.api.nvim_win_get_config(popup).row == 1, 'extra padding belongs below the popup')
assert(vim.api.nvim_win_get_cursor(popup)[2] == 3 and ui.peek_input() == 'popup draft')
messages[#messages + 1] = { role = 'assistant', content = 'Live popup reply' }
ui.render(messages, 'Ready', 'copilot', 'model-b', nil)
assert(vim.api.nvim_get_current_win() == popup)
assert(vim.api.nvim_win_get_cursor(popup)[1] == vim.api.nvim_buf_line_count(chat))
assert(vim.api.nvim_win_get_cursor(popup)[2] == 3 and ui.peek_input() == 'popup draft')
assert(table.concat(vim.api.nvim_buf_get_lines(chat, 0, -1, false), '\n'):find('Live popup reply', 1, true))
vim.api.nvim_feedkeys(vim.keycode('A<C-s>'), 'xt', false)
assert(sent == 'popup draft' and vim.api.nvim_get_current_win() == popup)
vim.api.nvim_buf_set_lines(chat, -1, -1, false, { 'return draft' })
press('<C-g>', 'i')
assert(not vim.api.nvim_win_is_valid(popup) and vim.api.nvim_get_current_win() == sidebar)
assert(ui.peek_input() == 'return draft' and ui.is_open())
press('<C-g>', 'i')
popup = vim.api.nvim_get_current_win()
press('<Esc>')
assert(not vim.api.nvim_win_is_valid(popup) and vim.api.nvim_get_current_win() == sidebar)
press('<C-g>')
popup = vim.api.nvim_get_current_win()
vim.api.nvim_win_close(popup, true)
assert(vim.wait(1000, function() return vim.api.nvim_get_current_win() == sidebar and ui.is_open() end))
press('<C-g>')
popup = vim.api.nvim_get_current_win()
press('q')
assert(not ui.is_open() and not vim.api.nvim_win_is_valid(popup) and not vim.api.nvim_win_is_valid(sidebar))
ui.open(function() sent = ui.take_input() end, ui.close)
assert(ui.peek_input() == 'return draft', 'closing the popup must preserve the draft')
sidebar = vim.api.nvim_get_current_win()
press('<C-g>')
popup = vim.api.nvim_get_current_win()
vim.api.nvim_win_close(sidebar, true)
assert(vim.wait(1000, function() return not ui.is_open() and not vim.api.nvim_win_is_valid(popup) end))
ui.open(function() sent = ui.take_input() end, ui.close)

vim.cmd('vsplit')
local unrelated = vim.api.nvim_get_current_win()
vim.cmd('close')
assert(not vim.api.nvim_win_is_valid(unrelated) and ui.is_open(), 'unrelated window closures must not close chat')
ui.close()
ui.open(function() end, ui.close)
local old_chat = vim.fn.bufwinid(chat)
vim.api.nvim_win_close(old_chat, true)
ui.open(function() end, ui.close) -- Reopen before the deferred WinClosed callback runs.
vim.wait(50, function() return false end)
assert(ui.is_open(), 'a stale window-close event must not close a reopened chat')
vim.cmd('close')
assert(vim.wait(1000, function() return not ui.is_open() end), 'manually closing the chat must reset the UI')
print('codeit ui tests passed')
