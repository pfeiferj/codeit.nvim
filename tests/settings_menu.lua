vim.opt.runtimepath:prepend(vim.fn.getcwd())
local menu = require('codeit.settings.menu')
local function press(buf, key)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
    if map.lhs == key then return map.callback() end
  end
  error('missing mapping: ' .. key)
end
local count, selected = 0, nil
local win, buf = menu.select({
  { label = 'Backend: openrouter', section = 'Main chat' },
  { label = 'Preset: fast', section = 'Presets' },
}, { prompt = 'Settings', format_item = function(item) return item.label end }, function(item)
  count, selected = count + 1, item
end)
assert(vim.wo[win].cursorline and not vim.bo[buf].modifiable)
assert(vim.api.nvim_win_get_cursor(win)[1] == 4)
local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
local groups = {}
for _, mark in ipairs(marks) do groups[mark[4].hl_group] = true end
assert(groups.CodeitSettingsHeading and groups.CodeitSettingsLabel and groups.CodeitSettingsValue)
press(buf, 'j')
assert(vim.api.nvim_win_get_cursor(win)[1] == 7, 'movement skips headings and blank lines')
press(buf, 'k')
assert(vim.api.nvim_win_get_cursor(win)[1] == 4)
vim.api.nvim_win_set_cursor(win, { 3, 0 })
press(buf, '<CR>')
assert(count == 0, 'headings cannot be selected')
press(buf, 'j')
press(buf, '<CR>')
vim.wait(20)
assert(count == 1 and selected.label == 'Backend: openrouter')
win, buf = menu.select({ 'one', 'two' }, { selected = 2 }, function(item)
  count, selected = count + 1, item
end)
assert(vim.api.nvim_win_get_cursor(win)[1] == 3)
vim.api.nvim_win_close(win, true)
assert(vim.wait(100, function() return count == 2 end))
assert(selected == nil, 'external close cancels exactly once')
win, buf = menu.select({}, {}, function(item) assert(item == nil); count = count + 1 end)
press(buf, '<CR>')
assert(count == 2)
press(buf, 'q')
vim.wait(20)
assert(count == 3)

-- Exercise the settings controller with actual cursor selections, not vim.ui.select.
package.loaded['codeit.providers'] = {
  models = function(_, callback)
    callback({ { id = 'z-model' }, { id = 'a-model', description = 'A model\nwith description' } })
  end,
}
local picker = require('codeit.settings.picker')
local base = { provider = 'openrouter', models = { openrouter = 'original', copilot = 'copilot' },
  request_options = { openrouter = {} } }
local applied, scope
vim.ui.select = function() error('settings must not invoke a search selector') end
vim.ui.input = function() error('model browsing must not require text input') end
local function current() return vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf() end
local function choose(text)
  local w, b = current()
  for row, line in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
    if line:find(text, 1, true) then
      vim.api.nvim_win_set_cursor(w, { row, 0 })
      press(b, '<CR>')
      return row
    end
  end
  error('missing row: ' .. text)
end
picker.show(base, function(values, selected_scope) applied, scope = values, selected_scope end)
local _, main_buf = current()
local lines = table.concat(vim.api.nvim_buf_get_lines(main_buf, 0, -1, false), '\n')
assert(lines:find('Main chat request options') < lines:find('Shared model presets'))
assert(lines:find('Shared model presets') < lines:find('Feature overrides'))
assert(lines:find('Feature overrides') < lines:find('Apply changes'))
local row = choose('Browse models:')
local _, model_buf = current()
assert(vim.api.nvim_buf_get_lines(model_buf, 1, 2, false)[1]:find('a-model', 1, true))
choose('a-model')
assert(vim.api.nvim_win_get_cursor(0)[1] == row, 'return restores selected setting')
assert(base.models.openrouter == 'original' and applied == nil)
choose('Apply for this session')
vim.wait(20)
assert(scope == 'session' and applied.models.openrouter == 'a-model')
picker.show(base, function() error('discard must not apply') end)
choose('Browse models:')
choose('z-model')
local _, discard_buf = current()
press(discard_buf, 'q')
vim.wait(20)
assert(base.models.openrouter == 'original')
print('codeit settings menu tests passed')
