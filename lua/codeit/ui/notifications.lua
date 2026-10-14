local M = {}
local namespace = vim.api.nvim_create_namespace('codeit_notifications')
local entries, buf, win = {}, nil, nil
local installed = false
local groups = {
  [vim.log.levels.ERROR] = { 'ERROR', 'DiagnosticError' },
  [vim.log.levels.WARN] = { 'WARN', 'DiagnosticWarn' },
  [vim.log.levels.INFO] = { 'INFO', 'DiagnosticInfo' },
  [vim.log.levels.DEBUG] = { 'DEBUG', 'Comment' },
  [vim.log.levels.TRACE] = { 'TRACE', 'DiagnosticHint' },
}

local function highlights()
  for _, group in pairs(groups) do
    vim.api.nvim_set_hl(0, 'CodeitNotify' .. group[1], { default = true, link = group[2] })
  end
end

local function close_window()
  if win and vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  win = nil
end

-- Wrap by display cells, not bytes, so wide and multibyte text fits the terminal.
local function wrap(text, width)
  local lines = {}
  for _, line in ipairs(vim.split(text:gsub('\t', '  '):gsub('\r', ''), '\n', { plain = true })) do
    local part = ''
    for index = 0, vim.fn.strchars(line) - 1 do
      local char = vim.fn.strcharpart(line, index, 1)
      if part ~= '' and vim.fn.strdisplaywidth(part .. char) > width then
        lines[#lines + 1], part = part, ''
      end
      part = part .. char
    end
    lines[#lines + 1] = part
  end
  return lines
end

local function render()
  if #entries == 0 then
    close_window()
    if buf and vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
    buf = nil
    return
  end
  local width = math.min(60, math.max(1, vim.o.columns - 4))
  local lines, spans = {}, {}
  for index, entry in ipairs(entries) do
    if index > 1 then lines[#lines + 1] = '' end
    local group = groups[entry.level] or groups[vim.log.levels.INFO]
    local text = '[' .. group[1] .. '] ' .. entry.message
    for _, line in ipairs(wrap(text, width)) do
      spans[#spans + 1] = { #lines, 'CodeitNotify' .. group[1] }
      lines[#lines + 1] = line
    end
  end
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'hide'
    vim.bo[buf].filetype = 'codeit_notification'
    vim.b[buf].codeit_notification = true
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  for _, span in ipairs(spans) do
    vim.api.nvim_buf_set_extmark(buf, namespace, span[1], 0, {
      end_row = span[1] + 1, hl_group = span[2], hl_eol = true,
    })
  end
  local config = {
    relative = 'editor', anchor = 'NE', row = 0, col = math.max(2, vim.o.columns - 1),
    width = width, height = math.min(#lines, math.max(1, vim.o.lines - vim.o.cmdheight - 4)),
    style = 'minimal', border = 'rounded', title = ' Codeit ', title_pos = 'center',
    focusable = false, zindex = 250,
  }
  -- Floats belong to a tab: recreate the view, but retain messages and their timers.
  if win and vim.api.nvim_win_is_valid(win)
    and vim.api.nvim_win_get_tabpage(win) ~= vim.api.nvim_get_current_tabpage() then
    close_window()
  end
  if not win or not vim.api.nvim_win_is_valid(win) then
    win = vim.api.nvim_open_win(buf, false, config)
    vim.wo[win].wrap = false
    vim.wo[win].winhighlight = 'Normal:NormalFloat,FloatBorder:FloatBorder'
  else
    vim.api.nvim_win_set_config(win, config)
  end
  -- When the terminal cannot fit the whole stack, keep the newest messages visible.
  vim.api.nvim_win_set_cursor(win, { #lines, 0 })
end

function M.notify(message, level, opts)
  if vim.in_fast_event() then
    vim.schedule(function() M.notify(message, level, opts) end)
    return
  end
  highlights()
  local entry = { message = tostring(message):gsub('^codeit:%s*', ''), level = level or vim.log.levels.INFO }
  entries[#entries + 1] = entry
  render()
  vim.defer_fn(function()
    for index, candidate in ipairs(entries) do
      if candidate == entry then table.remove(entries, index); break end
    end
    render()
  end, (opts and opts.timeout) or 4000)
end

function M.install()
  if installed then return end
  installed = true
  local notify = vim.notify
  -- Preserve other plugins' notifier and slash-command notification capture.
  vim.notify = function(message, level, opts)
    if (type(message) == 'string' and message:match('^codeit:'))
      or (opts and opts.title == 'Codeit') then
      return M.notify(message, level, opts)
    end
    return notify(message, level, opts)
  end
  local group = vim.api.nvim_create_augroup('CodeitNotifications', { clear = true })
  vim.api.nvim_create_autocmd({ 'TabEnter', 'VimResized' }, {
    group = group,
    callback = function() vim.schedule(render) end,
  })
  vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = highlights })
end

return M
