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
  local choice_lines = {}
  local first_choice_line
  for _, option in ipairs(options) do
    lines[#lines + 1] = '- **[' .. option.key .. ']** ' .. option.label
    first_choice_line = first_choice_line or #lines
    choice_lines[#lines] = option.id
  end
  lines[#lines + 1] = '- **[Esc]** ' .. (config.dismiss or 'Reject')
  lines[#lines + 1] = ''

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
  vim.wo[win].cursorline = true
  vim.api.nvim_win_set_cursor(win, { first_choice_line or #lines, 0 })
  local finished = false
  local function finish(choice)
    if finished then return end
    finished = true
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    callback(choice)
  end
  on_close(win, finish)
  vim.keymap.set('n', '<CR>', function()
    local choice = choice_lines[vim.api.nvim_win_get_cursor(win)[1]]
    if choice then finish(choice) end
  end, { buffer = buf, silent = true, desc = 'Select choice under cursor' })
  for _, option in ipairs(options) do
    vim.keymap.set('n', option.key, function() finish(option.id) end,
      { buffer = buf, nowait = true, silent = true, desc = option.label })
  end
  vim.keymap.set('n', '<Esc>', function() finish(nil) end,
    { buffer = buf, nowait = true, silent = true, desc = config.dismiss or 'Reject tool call' })
end

--- Keep the reviewer conversation open while questions are answered. The transcript is
--- read-only; the lower pane accepts follow-up questions without an extra choice.
function M.ask_reviewer(name, args, on_question, on_back)
  local lines = { '# Review tool call', '', '**Tool:** `' .. tostring(name) .. '`', '', '## Arguments', '' }
  vim.list_extend(lines, markdown.fence(args, 'json'))
  vim.list_extend(lines, { '', '## Conversation', '', 'Type in the lower pane; <C-s> or normal-mode <Enter> to send. <Esc> to go back.', '' })
  local transcript = vim.api.nvim_create_buf(false, true)
  local input = vim.api.nvim_create_buf(false, true)
  for _, buf in ipairs({ transcript, input }) do
    vim.bo[buf].bufhidden = 'wipe'
    markdown.enable(buf)
  end
  vim.api.nvim_buf_set_lines(transcript, 0, -1, false, lines)
  vim.bo[transcript].modifiable = false
  vim.api.nvim_buf_set_lines(input, 0, -1, false, { '' })
  if vim.api.nvim_get_mode().mode:sub(1, 1) == 'i' then vim.cmd.stopinsert() end
  local frame = geometry()
  local input_height = math.min(4, math.max(1, frame.height - 1))
  local transcript_height = frame.height - input_height - 1
  if transcript_height < 1 then transcript_height = 1 end
  local transcript_config = vim.tbl_extend('force', frame, { height = transcript_height, title = ' Tool-call reviewer ' })
  local transcript_win = vim.api.nvim_open_win(transcript, true, transcript_config)
  local input_config = vim.tbl_extend('force', frame, {
    row = frame.row + transcript_height + 1, height = input_height, title = ' Ask reviewer ',
  })
  local input_win = vim.api.nvim_open_win(input, true, input_config)
  for _, win in ipairs({ transcript_win, input_win }) do
    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true
  end
  local finished, waiting = false, false
  local function finish()
    if finished then return end
    finished = true
    if vim.api.nvim_win_is_valid(input_win) then vim.api.nvim_win_close(input_win, true) end
    if vim.api.nvim_win_is_valid(transcript_win) then vim.api.nvim_win_close(transcript_win, true) end
    on_back()
  end
  on_close(transcript_win, finish)
  on_close(input_win, finish)
  local function append(text)
    if finished or not vim.api.nvim_buf_is_valid(transcript) then return end
    local additions = vim.split(text, '\n', { plain = true })
    vim.bo[transcript].modifiable = true
    vim.api.nvim_buf_set_lines(transcript, -1, -1, false, additions)
    vim.bo[transcript].modifiable = false
    if vim.api.nvim_win_is_valid(transcript_win) then
      vim.api.nvim_win_set_cursor(transcript_win, { vim.api.nvim_buf_line_count(transcript), 0 })
    end
  end
  local function submit()
    if finished or waiting then return end
    local question = vim.trim(table.concat(vim.api.nvim_buf_get_lines(input, 0, -1, false), '\n'))
    if question == '' then return end
    vim.api.nvim_buf_set_lines(input, 0, -1, false, { '' })
    append('## You\n' .. question .. '\n\n*Waiting for reviewer…*')
    waiting = true
    on_question(question, function(answer)
      if finished or not vim.api.nvim_buf_is_valid(transcript) then return end
      vim.bo[transcript].modifiable = true
      vim.api.nvim_buf_set_lines(transcript, -2, -1, false, { '## Reviewer' })
      vim.bo[transcript].modifiable = false
      append((answer or 'No reviewer response') .. '\n')
      waiting = false
    end)
  end
  vim.keymap.set({ 'n', 'i' }, '<C-s>', function()
    if vim.api.nvim_get_mode().mode:sub(1, 1) == 'i' then vim.cmd.stopinsert() end
    submit()
  end, { buffer = input, silent = true, desc = 'Ask reviewer' })
  vim.keymap.set('n', '<CR>', submit, { buffer = input, silent = true, desc = 'Ask reviewer' })
  for _, buf in ipairs({ transcript, input }) do
    vim.keymap.set('n', '<Esc>', finish, { buffer = buf, silent = true, desc = 'Back to approval' })
  end
  vim.cmd.startinsert()
end

return M
