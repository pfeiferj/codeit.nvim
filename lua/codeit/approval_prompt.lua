local M = {}
local markdown = require('codeit.markdown')

local function geometry()
  local width = math.max(1, math.min(vim.o.columns - 4, math.floor(vim.o.columns * 0.85)))
  local height = math.max(1, math.min(vim.o.lines - 4, math.floor(vim.o.lines * 0.8)))
  return {
    relative = 'editor', width = width, height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = 'minimal', border = 'rounded', title_pos = 'center',
  }
end

local function on_close(win, finish)
  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(win), once = true,
    callback = function() vim.schedule(function() finish(nil) end) end,
  })
end

--- Show a non-blocking keyboard-driven choice window. Each option has a single-key normal-mode mapping.
function M.show(prompt, options, callback, config)
  config = config or {}
  local lines = { '# ' .. vim.trim(config.title or 'Approve tool call'), '' }
  vim.list_extend(lines, vim.split(prompt, '\n', { plain = true }))
  lines[#lines + 1] = ''
  lines[#lines + 1] = '## Choices'
  for _, option in ipairs(options) do
    lines[#lines + 1] = '- **[' .. option.key .. ']** ' .. option.label
  end
  lines[#lines + 1] = '- **[Esc]** ' .. (config.dismiss or 'Reject')
  lines[#lines + 1] = '' -- Park the cursor below the options, not over text.

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  markdown.enable(buf)
  vim.bo[buf].modifiable = false
  if vim.api.nvim_get_mode().mode:sub(1, 1) == 'i' then vim.cmd.stopinsert() end
  local win_config = geometry()
  win_config.title = config.title or ' Approve tool call '
  local win = vim.api.nvim_open_win(buf, true, win_config)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].cursorline = false
  vim.api.nvim_win_set_cursor(win, { #lines, 0 })
  local finished = false
  local function finish(choice)
    if finished then return end
    finished = true
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    callback(choice)
  end
  on_close(win, finish)
  for _, option in ipairs(options) do
    vim.keymap.set('n', option.key, function() finish(option.id) end,
      { buffer = buf, nowait = true, silent = true, desc = option.label })
  end
  vim.keymap.set('n', '<Esc>', function() finish(nil) end,
    { buffer = buf, nowait = true, silent = true, desc = config.dismiss or 'Reject tool call' })
end

--- Collect a multiline reviewer question alongside the tool call being reviewed.
--- Only text below the Question heading is submitted; closing the window returns to approval.
function M.ask_reviewer(name, args, callback)
  local lines = { '# Review tool call', '', '**Tool:** `' .. tostring(name) .. '`', '', '## Arguments', '' }
  vim.list_extend(lines, markdown.fence(args, 'json'))
  vim.list_extend(lines, { '', '## Question', '', 'Type below; <C-s> or normal-mode <Enter> to send; <Esc> to go back.', '' })
  local question_start = #lines - 1 -- zero-based first editable question line
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  markdown.enable(buf)
  if vim.api.nvim_get_mode().mode:sub(1, 1) == 'i' then vim.cmd.stopinsert() end
  local win_config = geometry()
  win_config.title = ' Ask tool-call reviewer '
  local win = vim.api.nvim_open_win(buf, true, win_config)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.api.nvim_win_set_cursor(win, { #lines, 0 })
  local finished = false
  local function finish(question)
    if finished then return end
    finished = true
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    callback(question)
  end
  on_close(win, finish)
  local function submit()
    local question = table.concat(vim.api.nvim_buf_get_lines(buf, question_start, -1, false), '\n')
    finish(vim.trim(question))
  end
  vim.keymap.set({ 'n', 'i' }, '<C-s>', submit, { buffer = buf, silent = true, desc = 'Ask reviewer' })
  vim.keymap.set('n', '<CR>', submit, { buffer = buf, silent = true, desc = 'Ask reviewer' })
  vim.keymap.set('n', '<Esc>', function() finish(nil) end,
    { buffer = buf, silent = true, desc = 'Back to approval' })
  vim.cmd.startinsert()
end

return M
