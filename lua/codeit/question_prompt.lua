local M = {}
local markdown = require('codeit.markdown')

--- Display the question in the popup, never in a command-line input prompt.
function M.show(question, choices, callback)
  if choices and #choices > 0 then
    local options, other = {}, {}
    for index, choice in ipairs(choices) do
      options[#options + 1] = { key = tostring(index % 10), id = choice, label = choice }
    end
    options[#options + 1] = { key = 'o', id = other, label = 'Other (type an answer)' }
    return require('codeit.approval_prompt').show(question, options, function(choice)
      if choice == other then return M.show(question, nil, callback) end
      callback(choice)
    end, { title = ' Codeit question ', dismiss = 'Cancel task' })
  end

  local lines = vim.split(question, '\n', { plain = true })
  vim.list_extend(lines, { '', '## Answer', '',
    '*Type below. Ctrl-S or normal-mode Enter: send; Esc: cancel task; Ctrl-G: chat context.*', '', '' })
  local draft_start = #lines - 1
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  markdown.enable(buf)
  if vim.api.nvim_get_mode().mode:sub(1, 1) == 'i' then vim.cmd.stopinsert() end
  local width, height = math.max(1, vim.o.columns - 4), math.max(1, vim.o.lines - 6)
  local frame = {
    relative = 'editor', width = width, height = height,
    row = math.max(0, math.floor((vim.o.lines - height - 2) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = 'minimal', border = 'rounded', title = ' Codeit question ', title_pos = 'center',
  }
  local close_pane = require('codeit.assistant_pane').open(frame)
  local win = vim.api.nvim_open_win(buf, true, frame)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.api.nvim_win_set_cursor(win, { draft_start + 1, 0 })
  local close_chat = require('codeit.popup_chat').attach(win)
  local finished = false
  local function finish(answer)
    if finished then return end
    finished = true
    if vim.api.nvim_get_mode().mode:sub(1, 1) == 'i' then vim.cmd.stopinsert() end
    close_chat()
    close_pane()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    callback(answer)
  end
  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(win), once = true,
    callback = function() vim.schedule(function() finish(nil) end) end,
  })
  local function submit()
    if finished then return end
    local answer = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, draft_start, -1, false), '\n'))
    if answer ~= '' then finish(answer) end
  end
  vim.keymap.set({ 'n', 'i' }, '<C-s>', submit, { buffer = buf, silent = true, desc = 'Send answer' })
  vim.keymap.set('n', '<CR>', submit, { buffer = buf, silent = true, desc = 'Send answer' })
  vim.keymap.set('n', '<Esc>', function() finish(nil) end,
    { buffer = buf, silent = true, desc = 'Cancel task' })
  vim.cmd.startinsert()
end

return M
