local M = {}
local namespace = vim.api.nvim_create_namespace('codeit_input')

--- A single-line answer field below read-only Markdown context.
function M.show(options, callback)
  options = options or {}
  for name, link in pairs({
    CodeitInputField = 'Visual', CodeitInputLabel = 'Title', CodeitInputHint = 'Comment',
  }) do
    vim.api.nvim_set_hl(0, name, { default = true, link = link })
  end
  local lines = vim.split(options.body or options.prompt or 'Enter a value', '\n', { plain = true })
  vim.list_extend(lines, { '', '## Input', '',
    'Enter / Ctrl-S: submit · normal-mode Esc: cancel · Ctrl-G: chat context', '', '' })
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.b[buf].codeit_approval = options.approval or false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  require('codeit.ui.markdown').enable(buf)
  vim.api.nvim_buf_set_extmark(buf, namespace, #lines - 5, 0, {
    end_col = #lines[#lines - 4], hl_group = 'CodeitInputLabel', priority = 200,
  })
  vim.api.nvim_buf_set_extmark(buf, namespace, #lines - 3, 0, {
    end_col = #lines[#lines - 2], hl_group = 'CodeitInputHint', priority = 200,
  })
  if options.safety_score or options.risk_unknown then
    local group = (options.risk_unknown or options.safety_score > 5)
      and 'CodeitApprovalRisk' or 'CodeitApprovalWarning'
    for row, line in ipairs(lines) do
      if line:match('^Summary: ') or line:match('^%*%*Safety score:%*%* ') then
        vim.api.nvim_buf_set_extmark(buf, namespace, row - 1, 0, {
          end_col = #line, hl_group = group, priority = 200,
        })
      end
    end
  end
  vim.bo[buf].modifiable = false
  if vim.api.nvim_get_mode().mode:sub(1, 1) == 'i' then vim.cmd.stopinsert() end
  local width, height = math.max(1, vim.o.columns - 4), math.max(1, vim.o.lines - 6)
  local frame = {
    relative = 'editor', width = width, height = height,
    row = math.max(0, math.floor((vim.o.lines - height - 2) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = 'minimal', border = 'rounded', title = options.title or ' Codeit input ', title_pos = 'center',
  }
  local close_pane = require('codeit.ui.assistant_pane').open(frame)
  local win = vim.api.nvim_open_win(buf, false, frame)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  local input = vim.api.nvim_create_buf(false, true)
  vim.bo[input].bufhidden = 'wipe'
  vim.b[input].codeit_approval = options.approval or false
  vim.api.nvim_buf_set_lines(input, 0, -1, false, { options.default or '' })
  vim.api.nvim_buf_set_extmark(input, namespace, 0, 0, { line_hl_group = 'CodeitInputField' })
  local field = vim.api.nvim_open_win(input, true, {
    relative = 'win', win = win, width = math.max(1, frame.width - 2), height = 1,
    row = math.max(0, frame.height - 3), col = 0, style = 'minimal', zindex = 51,
    border = 'rounded', title_pos = 'center',
    title = { { ' Input ', 'CodeitInputLabel' },
      { '— Enter: submit · Esc (normal): cancel · Ctrl-G: context ', 'CodeitInputHint' } },
  })
  vim.wo[field].wrap = false
  vim.api.nvim_win_set_cursor(field, { 1, #(options.default or '') })
  local close_chat = require('codeit.ui.popup_chat').attach(field)
  local finished = false
  local function finish(value)
    if finished then return end
    finished = true
    if vim.api.nvim_get_mode().mode:sub(1, 1) == 'i' then vim.cmd.stopinsert() end
    close_chat()
    close_pane()
    for _, window in ipairs({ field, win }) do
      if vim.api.nvim_win_is_valid(window) then vim.api.nvim_win_close(window, true) end
    end
    callback(value)
  end
  for _, window in ipairs({ field, win }) do
    vim.api.nvim_create_autocmd('WinClosed', {
      pattern = tostring(window), once = true,
      callback = function() vim.schedule(function() finish(nil) end) end,
    })
  end
  local function submit()
    if finished then return end
    local value = table.concat(vim.api.nvim_buf_get_lines(input, 0, -1, false), '\n')
    if value:find('\n', 1, true) then
      vim.notify('codeit: enter a single-line value', vim.log.levels.WARN)
      return
    end
    finish(value)
  end
  vim.keymap.set({ 'n', 'i' }, '<CR>', submit, { buffer = input, silent = true, desc = 'Submit input' })
  vim.keymap.set({ 'n', 'i' }, '<C-s>', submit, { buffer = input, silent = true, desc = 'Submit input' })
  for _, buffer in ipairs({ buf, input }) do
    vim.keymap.set('n', '<Esc>', function() finish(nil) end,
      { buffer = buffer, silent = true, nowait = true, desc = 'Cancel input' })
  end
  vim.cmd.startinsert()
end

return M
