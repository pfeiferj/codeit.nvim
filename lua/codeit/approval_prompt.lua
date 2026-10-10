local M = {}
local markdown = require('codeit.markdown')
local risk_namespace = vim.api.nvim_create_namespace('codeit_approval_risk')

local function geometry()
  local width = math.max(1, vim.o.columns - 4)
  local height = math.max(1, vim.o.lines - 6)
  return {
    relative = 'editor', width = width, height = height,
    row = math.max(0, math.floor((vim.o.lines - height - 2) / 2) - 1),
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
  local function highlight_risk()
    vim.api.nvim_buf_clear_namespace(buf, risk_namespace, 0, -1)
    if not config.risk_unknown and (not config.safety_score or config.safety_score <= 2) then return end
    for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if line:match('^Summary: ') or line:match('^%*%*Safety score:%*%* ') then
        vim.api.nvim_buf_set_extmark(buf, risk_namespace, row - 1, 0, {
          end_col = #line, hl_group = 'CodeitApprovalRisk', priority = 200,
        })
      end
    end
  end
  highlight_risk()
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
  return function(updated_prompt, updated_config)
    if finished or not vim.api.nvim_buf_is_valid(buf) then return end
    local replacement = vim.split(updated_prompt, '\n', { plain = true })
    local old_length = #vim.split(prompt, '\n', { plain = true })
    local shift = #replacement - old_length
    local cursor = vim.api.nvim_win_get_cursor(win)
    local shifted_choices = {}
    for line, id in pairs(choice_lines) do shifted_choices[line + shift] = id end
    choice_lines = shifted_choices
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, old_length, false, replacement)
    vim.bo[buf].modifiable = false
    if cursor[1] > old_length then
      vim.api.nvim_win_set_cursor(win, { cursor[1] + shift, cursor[2] })
    end
    prompt = updated_prompt
    config = updated_config or config
    highlight_risk()
  end
end

--- Use the chat UI with a tool-call header and reviewer-specific navigation.
function M.ask_reviewer(name, args, on_question, on_back)
  local header = { '# Review tool call', '', '**Tool:** `' .. tostring(name) .. '`', '', '## Arguments', '' }
  vim.list_extend(header, markdown.fence(args, 'json'))
  vim.list_extend(header, { '', '## Conversation', '', 'Type below; <C-s> or normal-mode <Enter> to send. <Esc> to go back. <C-g> to view chat context.', '' })
  local frame = geometry()
  frame.title = ' Tool-call reviewer '
  local close_pane = require('codeit.assistant_pane').open(frame)
  local chat = require('codeit.ui').new({
    name = 'codeit://reviewer',
    floating = true,
    popup_config = function() return frame end,
    header = header,
    assistant_label = 'Reviewer',
    draft_label = 'Question',
    slash_commands = false,
  })
  local messages = {}
  local finished, waiting = false, false
  local close_chat
  local function finish()
    if finished then return end
    finished = true
    if close_chat then close_chat() end
    close_pane()
    chat.destroy()
    on_back()
  end
  local function render()
    chat.render(messages, waiting and 'Waiting for reviewer…' or nil, nil, nil, nil, nil, not waiting)
  end
  local function submit()
    if finished or waiting then return end
    local question = chat.take_input()
    if not question then return end
    messages[#messages + 1] = { role = 'user', content = question }
    waiting = true
    render()
    on_question(question, function(answer)
      if finished then return end
      messages[#messages + 1] = { role = 'assistant', content = answer or 'No reviewer response' }
      waiting = false
      render()
    end)
  end
  if vim.api.nvim_get_mode().mode:sub(1, 1) == 'i' then vim.cmd.stopinsert() end
  local win = chat.open(submit, finish)
  close_chat = require('codeit.popup_chat').attach(win)
  on_close(win, finish)
  render()
  vim.cmd.startinsert()
end

return M
