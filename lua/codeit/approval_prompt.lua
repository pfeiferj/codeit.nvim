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
  local lines = vim.split(prompt, '\n', { plain = true })
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
  lines[#lines + 1] = '*<C-g>: view chat context; press again to return.*'

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  markdown.enable(buf)
  vim.bo[buf].modifiable = false
  if vim.api.nvim_get_mode().mode:sub(1, 1) == 'i' then vim.cmd.stopinsert() end
  local win_config = geometry()
  win_config.title = config.title or ' Approve tool call '
  local close_pane = require('codeit.assistant_pane').open(win_config)
  local win = vim.api.nvim_open_win(buf, true, win_config)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].cursorline = true
  vim.api.nvim_win_set_cursor(win, { first_choice_line or #lines, 0 })
  local close_chat = require('codeit.popup_chat').attach(win)
  local finished = false
  local function finish(choice)
    if finished then return end
    finished = true
    close_chat()
    close_pane()
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
  return function(updated_prompt)
    if finished or not vim.api.nvim_buf_is_valid(buf) then return end
    local replacement = vim.split(updated_prompt, '\n', { plain = true })
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, #vim.split(prompt, '\n', { plain = true }), false, replacement)
    vim.bo[buf].modifiable = false
    prompt = updated_prompt
  end
end

--- Keep the reviewer conversation and multiline question draft in one Markdown window.
function M.ask_reviewer(name, args, on_question, on_back)
  local header = { '# Review tool call', '', '**Tool:** `' .. tostring(name) .. '`', '', '## Arguments', '' }
  vim.list_extend(header, markdown.fence(args, 'json'))
  vim.list_extend(header, { '', '## Conversation', '', 'Type below; <C-s> or normal-mode <Enter> to send. <Esc> to go back. <C-g> to view chat context.', '' })
  local turns = {}
  local lines = vim.deepcopy(header)
  vim.list_extend(lines, { '## Question', '', '' })
  local draft_start = #lines - 1 -- zero-based first line of the draft
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  markdown.enable(buf)
  if vim.api.nvim_get_mode().mode:sub(1, 1) == 'i' then vim.cmd.stopinsert() end
  local frame = geometry()
  frame.title = ' Tool-call reviewer '
  local close_pane = require('codeit.assistant_pane').open(frame)
  local win = vim.api.nvim_open_win(buf, true, frame)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.api.nvim_win_set_cursor(win, { draft_start + 1, 0 })
  local close_chat = require('codeit.popup_chat').attach(win)
  local finished, waiting = false, false
  local function finish()
    if finished then return end
    finished = true
    close_chat()
    close_pane()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    on_back()
  end
  on_close(win, finish)
  local function render()
    if finished or not vim.api.nvim_buf_is_valid(buf) then return end
    local prefix = vim.deepcopy(header)
    for _, turn in ipairs(turns) do
      vim.list_extend(prefix, { '## You' })
      vim.list_extend(prefix, vim.split(turn.question, '\n', { plain = true }))
      prefix[#prefix + 1] = ''
      if turn.answer then
        prefix[#prefix + 1] = '## Reviewer'
        vim.list_extend(prefix, vim.split(turn.answer, '\n', { plain = true }))
      else
        prefix[#prefix + 1] = '*Waiting for reviewer…*'
      end
      prefix[#prefix + 1] = ''
    end
    vim.list_extend(prefix, { '## Question', '' })
    local cursor = vim.api.nvim_win_get_cursor(win)
    local draft_row = cursor[1] > draft_start and cursor[1] - draft_start or nil
    vim.api.nvim_buf_set_lines(buf, 0, draft_start, false, prefix)
    draft_start = #prefix
    if draft_row then
      vim.api.nvim_win_set_cursor(win, {
        math.min(draft_start + draft_row, vim.api.nvim_buf_line_count(buf)), cursor[2],
      })
    end
  end
  local function submit()
    if finished or waiting then return end
    local question = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, draft_start, -1, false), '\n'))
    if question == '' then return end
    vim.api.nvim_buf_set_lines(buf, draft_start, -1, false, { '' })
    local turn = { question = question }
    turns[#turns + 1] = turn
    waiting = true
    render()
    on_question(question, function(answer)
      if finished or not vim.api.nvim_buf_is_valid(buf) then return end
      turn.answer = answer or 'No reviewer response'
      waiting = false
      render()
    end)
  end
  vim.keymap.set({ 'n', 'i' }, '<C-s>', function()
    if vim.api.nvim_get_mode().mode:sub(1, 1) == 'i' then vim.cmd.stopinsert() end
    submit()
  end, { buffer = buf, silent = true, desc = 'Ask reviewer' })
  vim.keymap.set('n', '<CR>', submit, { buffer = buf, silent = true, desc = 'Ask reviewer' })
  vim.keymap.set('n', '<Esc>', finish, { buffer = buf, silent = true, desc = 'Back to approval' })
  vim.cmd.startinsert()
end

return M
