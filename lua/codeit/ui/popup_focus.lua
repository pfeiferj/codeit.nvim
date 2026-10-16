local M = {}
local popups = {}
local sequence = 0
local group = vim.api.nvim_create_augroup('codeit_popup_focus', { clear = true })

function M.track(win)
  sequence = sequence + 1
  popups[win] = sequence
end

vim.api.nvim_create_autocmd('WinEnter', {
  group = group,
  callback = function()
    local win = vim.api.nvim_get_current_win()
    if popups[win] then M.track(win) end
  end,
})
vim.api.nvim_create_autocmd('WinClosed', {
  group = group,
  callback = function(args) popups[tonumber(args.match)] = nil end,
})
vim.api.nvim_create_autocmd('TabEnter', {
  group = group,
  callback = function()
    local target, priority, recent
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if popups[win] then
        local config = vim.api.nvim_win_get_config(win)
        if config.relative ~= '' and not config.hide and config.focusable ~= false then
          local zindex = config.zindex or 50
          if not target or zindex > priority or zindex == priority and popups[win] > recent then
            target, priority, recent = win, zindex, popups[win]
          end
        end
      end
    end
    -- Tab navigation can select an ordinary window underneath an existing popup.
    if target then vim.api.nvim_set_current_win(target) end
  end,
})

return M
