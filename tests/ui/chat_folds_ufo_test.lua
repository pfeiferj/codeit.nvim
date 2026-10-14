-- Run with: nvim --headless -u NONE -c 'luafile tests/ui/chat_folds_ufo_test.lua'
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local detached, pending, completed, overrides = {}, 0, 0, 0
local original_buf = vim.api.nvim_get_current_buf()
-- Model UFO's buffer-local opt-out and asynchronous takeover after BufWinEnter.
package.loaded.ufo = {
  detach = function(buf)
    assert(vim.bo[buf].filetype == 'codeit', 'file buffers must retain UFO folding')
    detached[buf] = true
  end,
}
vim.api.nvim_create_autocmd('BufWinEnter', {
  callback = function(event)
    if vim.bo[event.buf].filetype ~= 'codeit' then return end
    pending = pending + 1
    local buf = event.buf
    vim.defer_fn(function()
      completed = completed + 1
      if detached[buf] then return end
      for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        vim.api.nvim_win_call(win, function()
          vim.wo.foldmethod = 'manual'
          vim.cmd('normal! zR')
        end)
      end
      overrides = overrides + 1
    end, 10)
  end,
})
local ui = require('codeit.ui')
ui.open(function() error('must not send') end, ui.close)
local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
local messages = { { role = 'user', content = 'Request' } }
local function row(text)
  for index, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line == text then return index end
  end
  error('missing line: ' .. text)
end
local function render()
  ui.render(messages, 'Thinking', 'test', 'test')
  assert(vim.wo[win].foldmethod == 'expr', 'chat must own its expression folds')
end
render()
messages[2] = { role = 'assistant', content = 'Inspecting' }
render()
messages[2].content = 'Inspecting the request.'
render()
messages[2].tool_calls = { { id = 'read', ['function'] = { name = 'read_file', arguments = '{}' } } }
render()
assert(vim.fn.foldclosed(row('*Calling `read_file`…*')) == row('**Activity**'))
assert(pending > 0, 'regression must schedule a competing fold update')
assert(vim.wait(1000, function() return completed == pending end, 10), 'competing update must finish')
assert(overrides == 0, 'detaching chat must cancel the asynchronous fold takeover')
assert(vim.wo[win].foldmethod == 'expr')
assert(vim.fn.foldclosed(row('*Calling `read_file`…*')) == row('**Activity**'),
  'the first activity section must stay closed between streaming renders')
assert(detached[buf] and not detached[original_buf], 'only chat buffers may opt out of UFO')
messages[3] = { role = 'tool', tool_call_id = 'read', content = 'Result' }
render()
assert(vim.fn.foldclosed(row('Result')) == row('**Activity**'))
vim.api.nvim_win_set_cursor(win, { row('**Activity**'), 0 })
vim.cmd('normal! za')
messages[3].content = 'Updated result'
render()
assert(vim.fn.foldclosed(row('Updated result')) == -1, 'manual expansion must survive rendering')
ui.toggle_popup()
assert(vim.wo.foldmethod == 'expr', 'popup must retain the same fold ownership')
assert(vim.fn.foldclosed(row('Updated result')) == -1)
ui.close()
vim.cmd('qa!')
