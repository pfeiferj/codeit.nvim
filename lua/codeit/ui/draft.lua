local M = {}

function M.attach(api, state, options, helpers)
  local M = api
  local function wrap_hint(text, width)
    local lines, line = {}, ''
    for word in text:gmatch('%S+') do
      local candidate = line == '' and word or (line .. ' ' .. word)
      if vim.fn.strdisplaywidth(candidate) <= width then
        line = candidate
      else
        if line ~= '' then lines[#lines + 1], line = { { line, 'Comment' } }, '' end
        for index = 0, vim.fn.strchars(word, true) - 1 do
          local char = vim.fn.strcharpart(word, index, 1, true)
          if line ~= '' and vim.fn.strdisplaywidth(line .. char) > width then
            lines[#lines + 1], line = { { line, 'Comment' } }, ''
          end
          line = line .. char
        end
      end
    end
    if line ~= '' then lines[#lines + 1] = { { line, 'Comment' } } end
    return lines
  end

  helpers.draft_hint = function()
    if not state.transcript or not vim.api.nvim_buf_is_valid(state.transcript) then return end
    local width
    -- Virtual lines are buffer-wide, so they must fit both the sidebar and popup.
    for _, win in ipairs({ state.transcript_win, state.sidebar_win }) do
      if vim.api.nvim_win_is_valid(win) then
        local available = math.max(1, vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff)
        width = math.min(width or available, available)
      end
    end
    if not width then return end
    local hint = state.can_send_message and 'Ctrl-S: send · Enter: newline (insert mode) · normal Enter: send'
      or 'Sending unavailable while busy · Your draft is kept'
    if state.draft_status and state.draft_status ~= '' then hint = state.draft_status .. ' · ' .. hint end
    if options.slash_commands ~= false then
      if state.slash_error or state.slash_hint then hint = (state.slash_error or state.slash_hint) .. ' · ' .. hint
      else hint = hint .. ' · Type / for commands · // sends a literal /' end
    end
    local heading = vim.api.nvim_buf_get_lines(state.transcript, state.draft_start - 2, state.draft_start - 1, false)[1]
    state.draft_hint_id = vim.api.nvim_buf_set_extmark(state.transcript, state.ui_ns, state.draft_start - 2, 0, {
      id = state.draft_hint_id,
      virt_lines = wrap_hint(hint, width),
      end_col = #heading,
      hl_group = not state.can_send_message and 'CodeitMessageDisabled' or nil,
      priority = 200,
    })
  end

  function M.peek_input()
    if not state.transcript or not vim.api.nvim_buf_is_valid(state.transcript) then return nil end
    local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(state.transcript, state.draft_start, -1, false), '\n'))
    if text == '' then return nil end
    return text
  end

  function M.take_input()
    local text = M.peek_input()
    if not text then return nil end
    helpers.close_palette()
    state.slash_hint, state.slash_error, state.dismissed = nil, nil, nil
    vim.api.nvim_buf_set_lines(state.transcript, state.draft_start, -1, false, { '' })
    helpers.focus_draft()
    return text
  end
end

return M
