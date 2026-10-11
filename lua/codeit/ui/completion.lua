local M = {}

function M.attach(api, state, options, helpers)
  local M = api
  local slash_commands = require('codeit.commands.slash')
  function helpers.disable_plugin_completion()
    if vim.api.nvim_get_current_buf() ~= state.transcript then return end
    -- Do not load optional completion plugins just to disable them in the chat.
    local cmp = package.loaded['cmp']
    if cmp then
      cmp.setup.buffer({ enabled = false })
      cmp.abort()
    end
    local blink = package.loaded['blink.cmp']
    if blink then blink.hide() end
  end
  function helpers.suppress_completion()
    if vim.api.nvim_get_current_buf() ~= state.transcript then return end
    if state.saved_completeopt == nil then
      state.saved_completeopt = vim.bo[state.transcript].completeopt
      local effective_completeopt = state.saved_completeopt ~= '' and state.saved_completeopt or vim.o.completeopt
      local flags = vim.split(effective_completeopt, ',', { plain = true, trimempty = true })
      flags = vim.tbl_filter(function(flag)
        return flag ~= 'menu' and flag ~= 'menuone' and flag ~= 'popup'
      end, flags)
      -- An empty local value would inherit the global menu settings again.
      if #flags == 0 then flags = { 'noselect' } end
      vim.bo[state.transcript].completeopt = table.concat(flags, ',')
    end
    if vim.fn.pumvisible() == 1 and vim.api.nvim_get_mode().mode:sub(1, 1) == 'i' then
      vim.fn.complete(vim.fn.col('.'), {})
    end
  end
  function helpers.close_palette()
    state.completion = nil
    if state.saved_completeopt ~= nil then
      if state.transcript and vim.api.nvim_buf_is_valid(state.transcript) then
        vim.bo[state.transcript].completeopt = state.saved_completeopt
      end
      state.saved_completeopt = nil
    end
    if state.palette_win and vim.api.nvim_win_is_valid(state.palette_win) then
      vim.api.nvim_win_close(state.palette_win, true)
    end
    state.palette_win = nil
  end

  function helpers.paint_palette()
    local current = state.completion
    if not current then return end
    if not state.palette_buf or not vim.api.nvim_buf_is_valid(state.palette_buf) then
      state.palette_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[state.palette_buf].bufhidden = 'hide'
    end
    local lines, width = {}, 1
    for _, item in ipairs(current.items) do
      local line = item.word .. '  ' .. item.menu
      lines[#lines + 1] = line
      width = math.max(width, vim.fn.strdisplaywidth(line))
    end
    vim.api.nvim_buf_set_lines(state.palette_buf, 0, -1, false, lines)
    local config = { relative = 'cursor', row = 1, col = 0, width = math.min(width, math.max(1, vim.o.columns - 4)),
      height = math.min(#lines, 8, math.max(1, vim.o.lines - 6)),
      style = 'minimal', border = 'rounded', focusable = false, zindex = 150 }
    if state.palette_win and vim.api.nvim_win_is_valid(state.palette_win) then
      vim.api.nvim_win_set_config(state.palette_win, config)
    else
      state.palette_win = vim.api.nvim_open_win(state.palette_buf, false, config)
      vim.wo[state.palette_win].wrap = false
    end
    vim.api.nvim_buf_clear_namespace(state.palette_buf, state.palette_ns, 0, -1)
    vim.api.nvim_buf_set_extmark(state.palette_buf, state.palette_ns, current.index - 1, 0,
      { line_hl_group = 'PmenuSel' })
    vim.api.nvim_win_set_cursor(state.palette_win, { current.index, 0 })
  end

  function M.refresh_slash(force)
    if options.slash_commands == false or not M.is_open()
      or vim.api.nvim_get_current_buf() ~= state.transcript then return end
    local cursor = vim.api.nvim_win_get_cursor(0)
    local lines = vim.api.nvim_buf_get_lines(state.transcript, state.draft_start, -1, false)
    local text = lines[1] or ''
    if #lines ~= 1 or cursor[1] ~= state.draft_start + 1 or cursor[2] ~= #text then
      helpers.close_palette()
      state.slash_hint = nil
      helpers.draft_hint()
      return
    end
    if force then state.dismissed = nil end
    if state.completion and state.completion.text == text and state.completion.row == cursor[1] then
      helpers.suppress_completion()
      return
    end
    helpers.close_palette()
    state.slash_error = nil
    local items, start_col, hint = slash_commands.complete(text)
    state.slash_hint = hint
    if text ~= state.dismissed and #items > 0 then
      state.completion = { items = items, index = 1, row = cursor[1], start_col = start_col, text = text }
      helpers.suppress_completion()
      helpers.paint_palette()
      state.slash_hint = (hint and (hint .. ' · ') or '')
        .. 'Tab / Shift-Tab or Ctrl-N / Ctrl-P: navigate · Enter: select · Esc: dismiss'
    elseif text:sub(1, 1) == '/' and text:sub(1, 2) ~= '//' then
      local command, args = slash_commands.parse(text)
      state.slash_hint = command and (slash_commands.validate(command, args) or 'Enter: run command')
        or (args or hint)
    end
    helpers.draft_hint()
  end

  function M.move_slash(direction)
    local existing = state.completion ~= nil
    M.refresh_slash(true)
    if not state.completion then return end
    if existing then
      state.completion.index = (state.completion.index - 1 + direction) % #state.completion.items + 1
    elseif direction < 0 then
      state.completion.index = #state.completion.items
    end
    helpers.paint_palette()
  end

  function M.dismiss_slash()
    state.dismissed = state.completion and state.completion.text or nil
    helpers.close_palette()
    state.slash_hint = nil
    helpers.draft_hint()
  end

  function M.accept_slash()
    M.refresh_slash()
    local current = state.completion
    if not current then return end
    local item = current.items[current.index]
    local suffix = item.command and item.command.args and ' ' or ''
    local word = item.word .. suffix
    helpers.close_palette()
    state.dismissed = current.text:sub(1, current.start_col) .. word
    vim.api.nvim_buf_set_text(state.transcript, current.row - 1, current.start_col,
      current.row - 1, #current.text, { word })
    vim.api.nvim_win_set_cursor(0, { current.row, #state.dismissed })
    -- Argument choices are a second selection step, never an implicit execution.
    M.refresh_slash(suffix ~= '')
  end

  function M.slash_error(message)
    helpers.close_palette()
    state.slash_error = message
    helpers.draft_hint()
  end

  function M.slash_help()
    M.take_input()
    vim.api.nvim_buf_set_lines(state.transcript, state.draft_start, -1, false, { '/' })
    vim.api.nvim_set_current_win(state.transcript_win)
    vim.api.nvim_win_set_cursor(state.transcript_win, { state.draft_start + 1, 1 })
    vim.cmd('startinsert!')
    M.refresh_slash(true)
  end

  function helpers.setup_completion()
    if options.slash_commands ~= false then
    vim.keymap.set('i', '<CR>', function()
      if state.completion then return '<Plug>(codeit-accept-slash)' end
      local text = M.peek_input()
      if text and (slash_commands.parse(text) ~= nil or text:sub(1, 2) == '//') then
        return '<Plug>(codeit-run-slash)'
      end
      return '<CR>'
    end, { buffer = state.transcript, expr = true, desc = 'Select or run slash command; otherwise newline' })
    vim.keymap.set('i', '<Plug>(codeit-accept-slash)', M.accept_slash,
      { buffer = state.transcript, silent = true })
    vim.keymap.set('i', '<Plug>(codeit-run-slash)', '<C-\\><C-n><Plug>(codeit-send)',
      { buffer = state.transcript, silent = true })
    local function navigate(direction, fallback)
      return function()
        local cursor = vim.api.nvim_win_get_cursor(0)
        local text = vim.api.nvim_get_current_line()
        if not state.completion and (cursor[1] ~= state.draft_start + 1 or cursor[2] ~= #text
          or #slash_commands.complete(text) == 0) then return fallback end
        return direction == 1 and '<Plug>(codeit-next-slash)' or '<Plug>(codeit-prev-slash)'
      end
    end
    vim.keymap.set('i', '<Plug>(codeit-next-slash)', function() M.move_slash(1) end,
      { buffer = state.transcript, silent = true })
    vim.keymap.set('i', '<Plug>(codeit-prev-slash)', function() M.move_slash(-1) end,
      { buffer = state.transcript, silent = true })
    for _, key in ipairs({ '<Tab>', '<C-n>' }) do
      vim.keymap.set('i', key, navigate(1, key), { buffer = state.transcript, expr = true })
    end
    for _, key in ipairs({ '<S-Tab>', '<C-p>' }) do
      vim.keymap.set('i', key, navigate(-1, key), { buffer = state.transcript, expr = true })
    end
    vim.keymap.set('i', '<Esc>', function()
      if state.completion then return '<Plug>(codeit-dismiss-slash)' end
      return '<Esc>'
    end, { buffer = state.transcript, expr = true })
    vim.keymap.set('i', '<Plug>(codeit-dismiss-slash)', M.dismiss_slash,
      { buffer = state.transcript, silent = true })
    local events = { 'TextChangedI', 'TextChangedP', 'CursorMovedI', 'CompleteChanged' }
    vim.api.nvim_clear_autocmds({ group = state.slash_group, event = events })
    vim.api.nvim_create_autocmd(events, {
      group = state.slash_group, buffer = state.transcript,
      callback = function() vim.schedule(function()
        if vim.api.nvim_get_mode().mode:sub(1, 1) == 'i' then M.refresh_slash() end
      end) end,
    })
    vim.api.nvim_clear_autocmds({ group = state.slash_group, event = { 'InsertLeave', 'BufLeave' } })
    vim.api.nvim_create_autocmd({ 'InsertLeave', 'BufLeave' }, {
      group = state.slash_group, buffer = state.transcript,
      callback = function() helpers.close_palette(); state.slash_hint = nil; helpers.draft_hint() end,
    })
    end
    vim.api.nvim_clear_autocmds({ group = state.slash_group, event = 'InsertEnter' })
    vim.api.nvim_create_autocmd('InsertEnter', {
      group = state.slash_group, buffer = state.transcript,
      callback = function()
        -- InsertEnter may load a completion plugin after our handler runs.
        vim.schedule(function()
          helpers.disable_plugin_completion()
          if vim.api.nvim_get_mode().mode:sub(1, 1) == 'i' then M.refresh_slash() end
        end)
      end,
    })
  end
end

return M
