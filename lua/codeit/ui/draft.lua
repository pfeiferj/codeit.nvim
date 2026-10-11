local M = {}

function M.attach(api, state, options, helpers)
  local M = api
  local status_animation
  function helpers.stop_status_animation()
    status_animation = nil
  end

  local function wrap_hint(text, width)
    local lines, line = {}, ''
    for gap, word in text:gmatch('(%s*)(%S+)') do
      local candidate = line == '' and word or (line .. gap .. word)
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
    for _ = 1, #(text:match('%s+$') or '') do
      if vim.fn.strdisplaywidth(line .. ' ') > width then
        lines[#lines + 1], line = { { line, 'Comment' } }, ''
      end
      line = line .. ' '
    end
    if line ~= '' then lines[#lines + 1] = { { line, 'Comment' } } end
    return lines
  end

  helpers.draft_hint = function()
    if not state.transcript or not vim.api.nvim_buf_is_valid(state.transcript) then
      helpers.stop_status_animation()
      return
    end
    local width
    -- Virtual lines are buffer-wide, so they must fit both the sidebar and popup.
    for _, win in ipairs({ state.transcript_win, state.sidebar_win }) do
      if vim.api.nvim_win_is_valid(win) then
        local available = math.max(1, vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff)
        width = math.min(width or available, available)
      end
    end
    if not width then
      helpers.stop_status_animation()
      return
    end
    local status = state.draft_status
    if status == 'Thinking' or (status == 'Waiting' and state.last_agent_activity) then
      if not status_animation or status_animation.status ~= status then
        local animation = { status = status, dots = 0 }
        status_animation = animation
        local function tick()
          if status_animation ~= animation then return end
          animation.dots = (animation.dots + 1) % 4
          helpers.draft_hint()
          if status_animation == animation then vim.defer_fn(tick, 1000) end
        end
        vim.defer_fn(tick, 1000)
      end
      if status == 'Thinking' then
        local dots = status_animation.dots
        status = status .. string.rep('.', dots) .. string.rep(' ', 3 - dots)
      else
        local seconds = math.max(0, math.floor((vim.uv.hrtime() - state.last_agent_activity) / 1e9))
        status = status .. string.format(' ( %ds )', seconds)
      end
    else
      helpers.stop_status_animation()
    end
    local hints = {}
    if status and status ~= '' then hints[#hints + 1] = status end
    if options.slash_commands ~= false and (state.slash_error or state.slash_hint) then
      hints[#hints + 1] = state.slash_error or state.slash_hint
    else
      if state.can_send_message then hints[#hints + 1] = 'Ctrl-S: send' end
      if options.slash_commands ~= false then hints[#hints + 1] = '/ commands' end
    end
    local hint = table.concat(hints, ' · ')
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
