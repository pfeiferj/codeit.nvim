vim.opt.runtimepath:prepend(vim.fn.getcwd())
local layout = require('codeit.ui.managed_tab')
local ui = require('codeit.ui')
local original_tab = vim.api.nvim_get_current_tabpage()
local original_win = vim.api.nvim_get_current_win()
local source = vim.api.nvim_get_current_buf()

local cases = {
  { 'named buffer', function()
    vim.api.nvim_buf_set_name(source, vim.fn.tempname())
    return function() vim.api.nvim_buf_set_name(source, '') end
  end },
  { 'modified buffer', function()
    vim.api.nvim_buf_set_lines(source, 0, -1, false, { 'unsaved text' })
    return function()
      vim.api.nvim_buf_set_lines(source, 0, -1, false, { '' })
      vim.bo[source].modified = false
    end
  end },
  { 'unmodified nonempty buffer', function()
    vim.api.nvim_buf_set_lines(source, 0, -1, false, { 'existing text' })
    vim.bo[source].modified = false
    return function()
      vim.api.nvim_buf_set_lines(source, 0, -1, false, { '' })
      vim.bo[source].modified = false
    end
  end },
  { 'special buffer', function()
    vim.bo[source].buftype = 'nofile'
    return function() vim.bo[source].buftype = '' end
  end },
  { 'multiple windows', function()
    vim.cmd('split')
    return function()
      vim.api.nvim_set_current_win(original_win)
      vim.cmd('only')
    end
  end },
  { 'multiple tabs', function()
    vim.cmd('tab split')
    vim.api.nvim_set_current_tabpage(original_tab)
    return function() vim.cmd('tabonly') end
  end },
  { 'hidden listed buffer', function()
    local hidden = vim.api.nvim_create_buf(true, false)
    return function() vim.api.nvim_buf_delete(hidden, { force = true }) end
  end },
}

for _, case in ipairs(cases) do
  local existing = {}
  for _, id in ipairs(vim.api.nvim_list_bufs()) do existing[id] = true end
  local cleanup = case[2]()
  local count = #vim.api.nvim_list_tabpages()
  layout.open()
  local managed = layout.tab()
  assert(managed ~= original_tab, case[1] .. ': must open a new tab')
  assert(#vim.api.nvim_list_tabpages() == count + 1)
  layout.leave()
  assert(vim.api.nvim_get_current_tabpage() == original_tab)
  vim.cmd('tabclose! ' .. vim.api.nvim_tabpage_get_number(managed))
  cleanup()
  for _, id in ipairs(vim.api.nvim_list_bufs()) do
    if not existing[id] then vim.api.nvim_buf_delete(id, { force = true }) end
  end
end

ui.open(function() end, ui.close)
assert(layout.tab() == original_tab, 'empty startup must reuse the original tab')
assert(#vim.api.nvim_list_tabpages() == 1)
assert(layout.windows()[1] == original_win)
assert(layout.buffer(original_win) == source and layout.user_visible(source))
assert(#vim.api.nvim_tabpage_list_wins(original_tab) == 2)
ui.close()
assert(vim.api.nvim_get_current_tabpage() == original_tab)
assert(#vim.api.nvim_tabpage_list_wins(original_tab) == 1)
assert(vim.api.nvim_win_get_buf(original_win) == source)
ui.open(function() end, ui.close)
assert(layout.tab() == original_tab and #vim.api.nvim_list_tabpages() == 1)
ui.close()
print('codeit startup tab tests passed')
