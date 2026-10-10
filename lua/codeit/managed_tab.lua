local M = {}
local buffers = require('codeit.file_buffer')
local tab, previous
local attachments = {}
local assistant_depth = 0

function M.tab()
  return tab and vim.api.nvim_tabpage_is_valid(tab) and tab or nil
end

function M.windows()
  local result = {}
  if not M.tab() then return result end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    local id = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_win_get_config(win).relative == '' and vim.bo[id].buftype == '' then
      result[#result + 1] = win
    end
  end
  return result
end

function M.buffer(win)
  for _, candidate in ipairs(M.windows()) do
    if candidate == win then return vim.api.nvim_win_get_buf(win) end
  end
end

local function observe(win)
  local id = M.buffer(win)
  if not id then
    if M.tab() and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_tabpage(win) == tab
      and vim.api.nvim_win_get_config(win).relative == '' then
      attachments[win] = { buffer = vim.api.nvim_win_get_buf(win), user = false }
    end
    return
  end
  local old = attachments[win]
  if old and old.buffer == id then return end
  local user = assistant_depth == 0
  -- A user-created split of an assistant view is not a new user attachment.
  if user and not old then
    for _, other in ipairs(M.windows()) do
      local entry = attachments[other]
      if entry and entry.buffer == id and not entry.user then user = false; break end
    end
  end
  attachments[win] = { buffer = id, user = user }
end

local group = vim.api.nvim_create_augroup('codeit_managed_tab', { clear = true })
vim.api.nvim_create_autocmd({ 'BufWinEnter', 'BufEnter' }, {
  group = group,
  callback = function() observe(vim.api.nvim_get_current_win()) end,
})
vim.api.nvim_create_autocmd('WinClosed', {
  group = group,
  callback = function(args) attachments[tonumber(args.match)] = nil end,
})

function M.user_visible(id)
  if not buffers.valid(id) or vim.bo[id].buftype ~= '' then return false end
  for _, win in ipairs(M.windows()) do
    local entry = attachments[win]
    if entry and entry.buffer == id and entry.user and M.buffer(win) == id then return true end
  end
  return false
end

function M.open()
  local current = vim.api.nvim_get_current_tabpage()
  if current ~= M.tab() then previous = current end
  if M.tab() then
    vim.api.nvim_set_current_tabpage(tab)
    return
  end
  local source = vim.api.nvim_get_current_buf()
  vim.cmd('tabnew')
  tab = vim.api.nvim_get_current_tabpage()
  attachments = {}
  vim.t[tab].codeit = true
  if buffers.valid(source) and vim.bo[source].buftype == '' then
    vim.api.nvim_win_set_buf(0, source)
  end
  local win = vim.api.nvim_get_current_win()
  attachments[win] = { buffer = vim.api.nvim_win_get_buf(win), user = true }
end

function M.leave()
  if vim.api.nvim_get_current_tabpage() == M.tab() and previous and vim.api.nvim_tabpage_is_valid(previous) then
    vim.api.nvim_set_current_tabpage(previous)
  end
end

function M.assistant(action, ...)
  assistant_depth = assistant_depth + 1
  local ok, result = pcall(action, ...)
  assistant_depth = assistant_depth - 1
  if not ok then error(result) end
  return result
end

function M.attach(win, id)
  return M.assistant(function()
    vim.api.nvim_win_set_buf(win, id)
    attachments[win] = { buffer = id, user = false }
  end)
end

function M.split(win, direction)
  return M.assistant(function()
    local created
    vim.api.nvim_win_call(win, function()
      vim.cmd(direction == 'vertical' and 'belowright vsplit' or 'belowright split')
      created = vim.api.nvim_get_current_win()
    end)
    attachments[created] = { buffer = vim.api.nvim_win_get_buf(created), user = false }
    return created
  end)
end

function M.describe(win)
  local id = M.buffer(win)
  if not id then return nil end
  return { window_id = win, buffer_id = id, path = vim.api.nvim_buf_get_name(id),
    modified = vim.bo[id].modified, width = vim.api.nvim_win_get_width(win),
    height = vim.api.nvim_win_get_height(win), user_attached = attachments[win]
      and attachments[win].buffer == id and attachments[win].user or false }
end

return M
