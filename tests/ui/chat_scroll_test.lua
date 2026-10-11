vim.opt.runtimepath:prepend(vim.fn.getcwd())
local ui = require('codeit.ui').new({
  name = 'codeit://scroll-test', floating = true,
  popup_config = function()
    return { relative = 'editor', row = 0, col = 0, width = 40, height = 18, style = 'minimal' }
  end,
})
ui.open(function() error('must not send') end, ui.close)
local win = vim.api.nvim_get_current_win()
local buf = vim.api.nvim_get_current_buf()
local messages = {
  { role = 'user', content = 'Old request' },
  { role = 'assistant', content = string.rep('Old response\n', 40) },
  { role = 'user', content = 'Latest request' },
}
local function row(text)
  for index, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line == text then return index end
  end
  error('missing line: ' .. text)
end
local function view()
  vim.cmd('redraw')
  return vim.api.nvim_win_call(win, vim.fn.winsaveview)
end
local function render()
  ui.render(messages, 'Working', 'test', 'test', nil, nil, false)
  return view()
end
local initial = render()
local prompt = row('Latest request') - 2
assert(initial.topline == prompt, 'new turns should anchor at the latest prompt')
local reply = { role = 'assistant', content = 'First output' }
messages[#messages + 1] = reply
assert(render().topline == initial.topline, 'short output should not move the viewport')
reply.content = 'First output\nSecond output\nThird output'
assert(render().topline == initial.topline, 'growing output should use the space below the prompt')
reply.content = string.rep('Output\n', 30)
local overflowing = render()
assert(overflowing.topline > prompt, 'output beyond the bottom must scroll')
assert(vim.fn.line('w$') == vim.api.nvim_buf_line_count(buf), 'overflow should keep the tail visible')
reply.content = reply.content .. 'More output\n'
assert(render().topline == overflowing.topline + 1, 'one new row should scroll only one row')
-- Folding the same output must use its visible height, not its buffer line count.
reply.reasoning_details = { { type = 'reasoning.text', text = reply.content } }
reply.content = nil
local folded = render()
assert(vim.fn.foldclosed(row('**Reasoning**')) ~= -1)
assert(folded.topline == prompt, 'auto-folding should bring the prompt back into view')
reply.content = string.rep('wrapped output ', 60)
assert(render().topline > prompt, 'wrapped screen rows should trigger scrolling')
reply.content = 'Short again'
assert(render().topline == prompt, 'shrinking output should restore the prompt')
-- Changes above the prompt should preserve the same visual anchor.
ui.render(messages, 'Working', 'test', 'test', 'Usage', nil, false)
assert(view().topline == row('Latest request') - 2, 'header changes should remap the prompt anchor')
-- A cursor in the transcript means the user is browsing, not following output.
render()
vim.api.nvim_win_set_cursor(win, { row('Old request'), 0 })
vim.api.nvim_win_call(win, function() vim.cmd('normal! zt') end)
local browsing = view()
reply.content = string.rep('New output\n', 50)
render()
assert(view().topline == browsing.topline, 'manual transcript browsing must not follow new output')
assert(vim.api.nvim_win_get_cursor(win)[1] == row('Old request'))
ui.close()
vim.cmd('qa!')
