local M = {}
local markdown = require('codeit.markdown')

--- Show saved chats in a wide, scrollable picker so summaries remain readable.
function M.show(entries, workspace, callback, delete_chat)
  entries = vim.list_extend({}, entries)
  local width = math.max(1, vim.o.columns - 4)
  local max_height = math.max(1, vim.o.lines - 6)
  local lines, choices
  local function render()
    lines = { '# Resume chat for ' .. workspace,
      delete_chat and '*Enter: resume  d: delete  Esc/q: close*' or '*Enter: resume  Esc/q: close*' }
    choices = {}
    for _, chat in ipairs(entries) do
      local summary = type(chat.summary) == 'string' and chat.summary ~= '' and '  ' .. chat.summary or ''
      lines[#lines + 1] = '- **' .. os.date('%Y-%m-%d %H:%M', tonumber(chat.updated_at) or 0) .. '**' .. summary
      choices[#lines] = chat
    end
    if #entries == 0 then lines[#lines + 1] = 'No saved chats.' end
  end
  render()

  local needed_height = 0
  for _, line in ipairs(lines) do
    needed_height = needed_height + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width))
  end
  local height = math.min(max_height, needed_height)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  markdown.enable(buf)
  vim.bo[buf].modifiable = false
  if vim.api.nvim_get_mode().mode:sub(1, 1) == 'i' then vim.cmd.stopinsert() end
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor', width = width, height = height,
    row = math.max(0, math.floor((vim.o.lines - height - 2) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = 'minimal', border = 'rounded', title = ' Chat history ', title_pos = 'center',
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].cursorline = true
  vim.api.nvim_win_set_cursor(win, { 3, 0 })
  local finished = false
  local function finish(chat)
    if finished then return end
    finished = true
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    callback(chat)
  end
  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(win), once = true,
    callback = function() vim.schedule(function() finish(nil) end) end,
  })
  vim.keymap.set('n', '<CR>', function()
    local chat = choices[vim.api.nvim_win_get_cursor(win)[1]]
    if chat then finish(chat) end
  end, { buffer = buf, silent = true, desc = 'Resume selected chat' })
  if delete_chat then
    local deleting = false
    vim.keymap.set('n', 'd', function()
      if finished or deleting then return end
      local row = vim.api.nvim_win_get_cursor(win)[1]
      local chat = choices[row]
      if not chat then return end
      deleting = true
      vim.ui.select({ 'Cancel', 'Delete' }, {
        prompt = 'Permanently delete chat ' .. chat.id .. '?',
      }, function(choice)
        deleting = false
        if choice ~= 'Delete' or finished or not vim.api.nvim_win_is_valid(win) then return end
        local ok, err = delete_chat(chat)
        if not ok then
          vim.notify('codeit: could not delete chat: ' .. tostring(err), vim.log.levels.ERROR)
          return
        end
        for index, entry in ipairs(entries) do
          if entry == chat then table.remove(entries, index); break end
        end
        render()
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].modifiable = false
        vim.api.nvim_win_set_cursor(win, { math.min(row, #lines), 0 })
      end)
    end, { buffer = buf, silent = true, desc = 'Delete selected chat' })
  end
  for _, key in ipairs({ '<Esc>', 'q' }) do
    vim.keymap.set('n', key, function() finish(nil) end,
      { buffer = buf, silent = true, desc = 'Close chat history' })
  end
end

return M
