local M = {}
local markdown = require('codeit.markdown')

local transcript, input, transcript_win, input_win
local billing_line
local header_ns = vim.api.nvim_create_namespace('codeit_sticky_header')

local function update_header()
  if not transcript or not vim.api.nvim_buf_is_valid(transcript) then return end
  vim.api.nvim_buf_clear_namespace(transcript, header_ns, 0, -1)
  if not transcript_win or not vim.api.nvim_win_is_valid(transcript_win) then return end
  local info = vim.fn.getwininfo(transcript_win)[1]
  if not billing_line or not info or info.topline <= 2 then return end
  local width = vim.api.nvim_win_get_width(transcript_win)
  local count = vim.api.nvim_buf_line_count(transcript)
  local row = info.topline - 1
  if row >= count then return end
  vim.api.nvim_buf_set_extmark(transcript, header_ns, row, 0, {
    virt_text = { { billing_line .. string.rep(' ', math.max(0, width - vim.fn.strdisplaywidth(billing_line))), 'WinBar' } },
    virt_text_win_col = 0,
    priority = 200,
  })
end

vim.api.nvim_create_autocmd('WinScrolled', {
  callback = function(args)
    if tonumber(args.match) == transcript_win then update_header() end
  end,
})

local function valid(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function scratch(name, editable)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  markdown.enable(buf)
  vim.bo[buf].modifiable = editable
  return buf
end

function M.is_open()
  return valid(transcript_win) and valid(input_win)
end

function M.open(on_send, on_close)
  if M.is_open() then
    vim.api.nvim_set_current_win(input_win)
    return
  end
  -- Recover if one pane was closed manually.
  M.close()
  if not transcript or not vim.api.nvim_buf_is_valid(transcript) then
    transcript = scratch('codeit://chat', false)
  end
  if not input or not vim.api.nvim_buf_is_valid(input) then
    input = scratch('codeit://input', true)
  end
  vim.cmd('botright 70vsplit')
  transcript_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(transcript_win, transcript)
  vim.wo[transcript_win].wrap = true
  vim.wo[transcript_win].number = false
  vim.wo[transcript_win].relativenumber = false
  vim.cmd('botright 8split')
  input_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(input_win, input)
  vim.wo[input_win].wrap = true
  vim.wo[input_win].number = false
  vim.wo[input_win].relativenumber = false
  vim.keymap.set('n', '<CR>', on_send, { buffer = input, desc = 'Send codeit message' })
  vim.keymap.set('i', '<C-s>', function()
    vim.cmd('stopinsert')
    on_send()
  end, { buffer = input, desc = 'Send codeit message' })
  vim.keymap.set('n', 'q', on_close, { buffer = input, desc = 'Close codeit chat' })
  vim.keymap.set('n', 'q', on_close, { buffer = transcript, desc = 'Close codeit chat' })
end

function M.close()
  if valid(input_win) then vim.api.nvim_win_close(input_win, true) end
  if valid(transcript_win) then vim.api.nvim_win_close(transcript_win, true) end
  input_win, transcript_win = nil, nil
  if transcript and vim.api.nvim_buf_is_valid(transcript) then
    vim.api.nvim_buf_clear_namespace(transcript, header_ns, 0, -1)
  end
end

function M.take_input()
  if not input or not vim.api.nvim_buf_is_valid(input) then return nil end
  local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(input, 0, -1, false), '\n'))
  if text == '' then return nil end
  vim.api.nvim_buf_set_lines(input, 0, -1, false, { '' })
  return text
end

function M.render(messages, status, provider, model, billing)
  if not transcript or not vim.api.nvim_buf_is_valid(transcript) then return end
  local lines = { '# Codeit (' .. provider .. ': ' .. model .. ')' }
  if billing then table.insert(lines, '> ' .. billing) end
  billing_line = billing
  table.insert(lines, '')
  for _, message in ipairs(messages) do
    if message.role ~= 'system' then
      local label = ({ user = 'You', assistant = 'Assistant', tool = 'Tool' })[message.role] or message.role
      if message.role == 'tool' then label = 'Tool: ' .. (message.name or message.tool_call_id or '') end
      table.insert(lines, '## ' .. label)
      local content = message.content
      if type(content) == 'table' then
        local parts = {}
        for _, part in ipairs(content) do
          if part.type == 'text' then table.insert(parts, part.text or '') end
        end
        content = table.concat(parts, '\n')
      end
      if type(content) == 'string' and content ~= '' then
        vim.list_extend(lines, vim.split(content, '\n', { plain = true }))
      end
      for _, call in ipairs(message.tool_calls or {}) do
        table.insert(lines, '*Calling `' .. (call['function'] and call['function'].name or 'unknown tool') .. '`…*')
      end
      table.insert(lines, '')
    end
  end
  if status and status ~= '' then table.insert(lines, '* ' .. status) end
  vim.bo[transcript].modifiable = true
  vim.api.nvim_buf_set_lines(transcript, 0, -1, false, lines)
  vim.bo[transcript].modifiable = false
  if valid(transcript_win) then
    vim.api.nvim_win_set_cursor(transcript_win, { #lines, 0 })
  end
  update_header()
end

return M
