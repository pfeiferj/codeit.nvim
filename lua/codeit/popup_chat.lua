local M = {}

--- Overlay the popup with a separate read-only transcript, leaving its state intact.
--- Returns an idempotent cleanup to call before completing the pending prompt.
function M.attach(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local chat_win, chat_buf, chat_view
  local finished = false
  local function hide()
    if chat_win and vim.api.nvim_win_is_valid(chat_win) then
      vim.api.nvim_win_call(chat_win, function() chat_view = vim.fn.winsaveview() end)
      vim.api.nvim_win_close(chat_win, true)
    end
    chat_win, chat_buf = nil, nil
    if not finished and vim.api.nvim_win_is_valid(win) then vim.api.nvim_set_current_win(win) end
  end
  local function toggle()
    if finished or not vim.api.nvim_win_is_valid(win) then return end
    if chat_win and vim.api.nvim_win_is_valid(chat_win) then return hide() end
    if vim.api.nvim_get_mode().mode:sub(1, 1) == 'i' then vim.cmd.stopinsert() end
    local lines = require('codeit.ui').chat_lines()
    if #lines == 0 then lines = { '(No chat messages yet.)' } end
    chat_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[chat_buf].bufhidden = 'wipe'
    vim.api.nvim_buf_set_lines(chat_buf, 0, -1, false, lines)
    require('codeit.markdown').enable(chat_buf)
    vim.bo[chat_buf].modifiable = false
    local width = math.max(1, math.min(vim.o.columns - 4, math.floor(vim.o.columns * 0.85)))
    local height = math.max(1, math.min(vim.o.lines - 4, math.floor(vim.o.lines * 0.8)))
    chat_win = vim.api.nvim_open_win(chat_buf, true, {
      relative = 'editor', width = width, height = height,
      row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
      col = math.max(0, math.floor((vim.o.columns - width) / 2)),
      style = 'minimal', border = 'rounded',
      title = ' Chat context — Ctrl-G / Esc: back ', title_pos = 'center',
      zindex = math.max(50, vim.api.nvim_win_get_config(win).zindex or 50) + 1,
    })
    vim.wo[chat_win].wrap = true
    vim.wo[chat_win].linebreak = true
    if chat_view then
      vim.api.nvim_win_call(chat_win, function() vim.fn.winrestview(chat_view) end)
    else
      vim.api.nvim_win_set_cursor(chat_win, { #lines, 0 })
      vim.api.nvim_win_call(chat_win, function() vim.cmd('normal! zb') end)
    end
    for _, key in ipairs({ '<C-g>', '<Esc>', 'q' }) do
      vim.keymap.set('n', key, hide, { buffer = chat_buf, silent = true, nowait = true,
        desc = 'Return to pending popup' })
    end
  end
  vim.keymap.set({ 'n', 'i' }, '<C-g>', toggle, { buffer = buf, silent = true,
    desc = 'View chat context (Ctrl-G to return)' })
  local closed = vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(win), once = true,
    callback = function()
      finished = true
      vim.schedule(hide)
    end,
  })
  return function()
    if finished then return hide() end
    finished = true
    pcall(vim.api.nvim_del_autocmd, closed)
    hide()
    if vim.api.nvim_buf_is_valid(buf) then
      for _, mode in ipairs({ 'n', 'i' }) do pcall(vim.keymap.del, mode, '<C-g>', { buffer = buf }) end
    end
  end
end

return M
