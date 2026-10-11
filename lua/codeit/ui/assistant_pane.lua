local M = {}
local markdown = require('codeit.ui.markdown')
local explanation

-- Tool-only replies do not erase an explanation, but a new user turn does.
function M.set_messages(messages)
  explanation = nil
  for _, message in ipairs(messages) do
    if message.role == 'user' then explanation = nil end
    if message.role == 'assistant' then
      local content = message.content
      if type(content) == 'table' then
        local parts = {}
        for _, part in ipairs(content) do
          if part.type == 'text' then parts[#parts + 1] = part.text or '' end
        end
        content = table.concat(parts, '\n')
      end
      if type(content) == 'string' and vim.trim(content) ~= '' then explanation = content end
    end
  end
end

--- Reserve space above an editor-relative popup. Returns an idempotent cleanup.
function M.open(frame, top_row)
  if not explanation or vim.o.lines < 10 then return function() end end
  local lines = vim.split(explanation, '\n', { plain = true })
  local rows = 0
  for _, line in ipairs(lines) do
    rows = rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / frame.width))
  end
  local height = math.min(rows, math.max(1, math.floor((vim.o.lines - 4) * 0.3)))
  local available = vim.o.lines - 4
  frame.height = math.max(1, math.min(frame.height, available - height - 2))
  local top = top_row or math.max(0, math.floor((vim.o.lines - frame.height - height - 4) / 2))
  frame.row = top + height + 2
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  markdown.enable(buf)
  vim.bo[buf].modifiable = false
  local win = vim.api.nvim_open_win(buf, false, {
    relative = 'editor', row = top, col = frame.col, width = frame.width, height = height,
    style = 'minimal', border = 'rounded', title = ' Assistant ', title_pos = 'center',
    zindex = frame.zindex or 50,
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  return function()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end
end

--- Keep vim.ui integrations: reserve space above their float when one is opened.
--- Command-line input still gets an explanation pane at the top of the editor.
function M.question()
  if not explanation or vim.o.lines < 10 then return function() end end
  local frame = {
    width = math.max(1, math.min(vim.o.columns - 4, math.floor(vim.o.columns * 0.85))),
    height = 1, col = math.max(0, math.floor(vim.o.columns * 0.075)),
  }
  local close = M.open(frame, 0)
  local finished, creating = false, false
  local known = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do known[win] = true end
  local autocmd
  autocmd = vim.api.nvim_create_autocmd('WinNew', {
    callback = function()
      if creating then return end
      vim.schedule(function()
        if finished then return end
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          if not known[win] then
            known[win] = true
            local config = vim.api.nvim_win_get_config(win)
            if config.relative ~= '' then
              close()
              -- Normalize picker-relative positioning so the panes cannot overlap.
              config.relative, config.win, config.bufpos, config.anchor = 'editor', nil, nil, 'NW'
              config.col = math.max(0, math.floor((vim.o.columns - config.width) / 2))
              creating = true
              close = M.open(config)
              creating = false
              for _, current in ipairs(vim.api.nvim_list_wins()) do known[current] = true end
              vim.api.nvim_win_set_config(win, config)
              break
            end
          end
        end
      end)
    end,
  })
  return function()
    if finished then return end
    finished = true
    vim.api.nvim_del_autocmd(autocmd)
    close()
  end
end

return M
