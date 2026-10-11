local M = {}
local markdown = require('codeit.ui.markdown')

--- Show saved chats in a wide, scrollable picker so summaries remain readable.
function M.show(entries, workspace, callback, delete_chat, archive_chat)
  entries = vim.list_extend({}, entries)
  local width = math.max(1, vim.o.columns - 4)
  local max_height = math.max(1, vim.o.lines - 6)
  local lines, choices
  local function render()
    local actions = (delete_chat and '  d: delete' or '') .. (archive_chat and '  a: archive' or '')
    lines = { '# Resume chat for ' .. workspace,
      '*Enter: resume' .. actions .. (actions ~= '' and '  V: select multiple chats' or '') .. '  Esc/q: close*' }
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
  if delete_chat or archive_chat then
    local pending = false
    local function remove_selected(action, first, last)
      if finished or pending then return end
      local selected = {}
      for row = first, last do
        if choices[row] then selected[#selected + 1] = choices[row] end
      end
      if #selected == 0 then return end
      pending = true
      local prefix = action.key == 'd' and 'Permanently delete ' or 'Archive '
      vim.ui.select({ 'Cancel', action.label }, {
        prompt = #selected == 1 and prefix .. 'chat ' .. selected[1].id .. '?'
          or prefix .. #selected .. ' chats?',
      }, function(choice)
        pending = false
        if choice ~= action.label or finished or not vim.api.nvim_win_is_valid(win) then return end
        for _, chat in ipairs(selected) do
          local ok, err = action.handler(chat)
          if not ok then
            vim.notify('codeit: could not ' .. action.verb .. ' chat: ' .. tostring(err), vim.log.levels.ERROR)
          else
            for index, entry in ipairs(entries) do
              if entry == chat then table.remove(entries, index); break end
            end
          end
        end
        render()
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].modifiable = false
        vim.api.nvim_win_set_cursor(win, { math.min(first, #lines), 0 })
      end)
    end
    for _, action in ipairs({
      { key = 'd', label = 'Delete', verb = 'delete', handler = delete_chat },
      { key = 'a', label = 'Archive', verb = 'archive', handler = archive_chat },
    }) do
      if action.handler then
        vim.keymap.set('n', action.key, function()
          local row = vim.api.nvim_win_get_cursor(win)[1]
          remove_selected(action, row, row)
        end, { buffer = buf, silent = true, desc = action.label .. ' selected chat' })
        vim.keymap.set('x', action.key, function()
          local anchor = vim.fn.line('v')
          local row = vim.api.nvim_win_get_cursor(win)[1]
          vim.cmd.normal({ args = { vim.api.nvim_replace_termcodes('<Esc>', true, false, true) }, bang = true })
          remove_selected(action, math.min(anchor, row), math.max(anchor, row))
        end, { buffer = buf, silent = true, desc = action.label .. ' selected chats' })
      end
    end
  end
  for _, key in ipairs({ '<Esc>', 'q' }) do
    vim.keymap.set('n', key, function() finish(nil) end,
      { buffer = buf, silent = true, desc = 'Close chat history' })
  end
end

return M
