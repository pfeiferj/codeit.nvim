vim.opt.runtimepath:prepend(vim.fn.getcwd())
local input = require('codeit.ui.input')
vim.ui.input = function() error('must not use command-line input') end
local function mapping(buf, key, mode)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, mode or 'n')) do
    if map.lhs:lower() == key:lower() then return map.callback end
  end
  error('missing mapping: ' .. key)
end
local function popup(options)
  local calls, result = 0, false
  input.show(options, function(value) calls, result = calls + 1, value end)
  local field, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local context = vim.api.nvim_win_get_config(field).win
  return field, buf, context, function(expected)
    assert(vim.wait(1000, function() return calls == 1 end))
    assert(result == expected)
    assert(not vim.api.nvim_win_is_valid(field) and not vim.api.nvim_win_is_valid(context))
    vim.wait(10)
    assert(calls == 1, 'popup completion must be idempotent')
  end
end
local field, buf, context, check = popup({
  title = ' Confirm approval ', approval = true, risk_score = 8, expected = 'approve run_command',
  body = '# Confirm tool\n\nSummary: Deletes files.\n\n**Risk score:** 8/10\n\nType **`approve run_command`** exactly.',
})
local body = vim.api.nvim_win_get_buf(context)
assert(not vim.bo[body].modifiable and vim.bo[buf].modifiable, 'context must be read-only; only the field is editable')
assert(vim.b[body].codeit_approval and vim.b[buf].codeit_approval)
assert(vim.api.nvim_win_get_config(context).border[1] == '╭', 'use the standard rounded popup border')
assert(vim.api.nvim_win_get_config(field).title[1][1] == ' Input ')
local ns = vim.api.nvim_create_namespace('codeit_input')
local marks = vim.api.nvim_buf_get_extmarks(body, ns, 0, -1, { details = true })
local groups = {}
for _, mark in ipairs(marks) do groups[mark[4].hl_group] = (groups[mark[4].hl_group] or 0) + 1 end
assert(groups.CodeitInputLabel and groups.CodeitInputHint and groups.CodeitApprovalRisk == 2,
  'highlight input labels, hints, and risky risk assessment')
local field_marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
assert(field_marks[1][4].line_hl_group == 'CodeitInputField')
local function check_hint(value, hint, errors)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { value })
  local found_hint, found_errors = nil, {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local details = mark[4]
    if details.virt_text then
      assert(mark[3] == #value and details.virt_text_pos == 'overlay')
      assert(details.virt_text[1][2] == 'CodeitInputHint')
      found_hint = details.virt_text[1][1]
    elseif details.hl_group == 'CodeitInputError' then
      found_errors[#found_errors + 1] = { mark[3], details.end_col }
    end
  end
  assert(found_hint == hint, 'hint must show only the untyped suffix')
  assert(vim.deep_equal(found_errors, errors), vim.inspect(found_errors))
  assert(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == value, 'hint must not change the actual input')
end
check_hint('', 'approve run_command', {})
check_hint('app', 'rove run_command', {})
check_hint('axp', 'rove run_command', { { 1, 2 } })
check_hint('app', 'rove run_command', {})
check_hint('', 'approve run_command', {})
check_hint('approve run_command!', nil, { { 19, 20 } })
check_hint('approve run_command', nil, {})
mapping(buf, '<CR>', 'i')()
check('approve run_command')

field, buf, context, check = popup({ prompt = 'Model ID', default = 'vendor/model' })
assert(not vim.b[buf].codeit_approval, 'non-approval inputs must retain the normal idle delay')
assert(vim.api.nvim_get_current_line() == 'vendor/model')
assert(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) == 1, 'ordinary input must not have validation hints')
assert(vim.api.nvim_win_get_cursor(field)[2] == #'vendor/model')
mapping(buf, '<C-s>')()
check('vendor/model')

field, buf, context, check = popup({ expected = 'aé界z', default = 'aé' })
check_hint('aé', '界z', {})
check_hint('a界界', 'z', { { 1, 4 } })
check_hint('aé界z', nil, {})
mapping(buf, '<CR>')()
check('aé界z')

field, buf, context, check = popup({ prompt = 'Optional reason' })
mapping(buf, '<CR>')()
check('')
field, buf, context, check = popup({ prompt = 'Cancel' })
mapping(buf, '<Esc>')()
check(nil)
for _, close_context in ipairs({ false, true }) do
  field, buf, context, check = popup({ prompt = 'External close' })
  vim.api.nvim_win_close(close_context and context or field, true)
  check(nil)
end

field, buf, context, check = popup({ prompt = 'Context', default = 'draft' })
mapping(buf, '<C-g>')()
local chat = vim.api.nvim_get_current_buf()
assert(chat ~= buf and vim.api.nvim_win_is_valid(field))
mapping(chat, '<C-g>')()
assert(vim.api.nvim_get_current_buf() == buf and vim.api.nvim_get_current_line() == 'draft')
mapping(buf, '<Esc>')()
check(nil)
print('codeit input popup tests passed')
