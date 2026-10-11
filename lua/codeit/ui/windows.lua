local M = {}

function M.attach(api, state, options, helpers)
  local M = api
  local markdown = require('codeit.ui.markdown')
  function helpers.update_header()
    for _, win in ipairs({ state.transcript_win, state.sidebar_win }) do
      if vim.api.nvim_win_is_valid(win) then
        vim.wo[win].winbar = state.billing_line and ('%#WinBar#' .. state.billing_line:gsub('%%', '%%%%')) or ''
      end
    end
  end

  local function valid(win)
    return win and vim.api.nvim_win_is_valid(win)
  end

  local function scratch()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, options.name or 'codeit://chat')
    vim.bo[buf].bufhidden = options.floating and 'wipe' or 'hide'
    vim.bo[buf].swapfile = false
    vim.b[buf].completion = false
    markdown.enable(buf)
    local lines = vim.deepcopy(state.chat_lines)
    if #lines > 0 then table.insert(lines, '') end
    vim.list_extend(lines, { '## ' .. (options.draft_label or 'Message'), '', '' })
    state.draft_start = #lines - 1
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return buf
  end

  function helpers.focus_draft()
    if valid(state.transcript_win) then
      vim.api.nvim_set_current_win(state.transcript_win)
      vim.api.nvim_win_set_cursor(state.transcript_win, { math.max(state.draft_start + 1, vim.api.nvim_buf_line_count(state.transcript)), 0 })
    end
  end

  function M.is_open()
    return valid(state.transcript_win)
  end

  function helpers.popup_config()
    if options.popup_config then return options.popup_config() end
    local width = math.max(1, vim.o.columns - 4)
    local height = math.max(1, vim.o.lines - 6)
    return {
      relative = 'editor', width = width, height = height,
      row = math.max(0, math.floor((vim.o.lines - height - 2) / 2) - 1),
      col = math.max(0, math.floor((vim.o.columns - width) / 2)),
      style = 'minimal', border = 'rounded',
      title = ' Codeit chat — Ctrl-G / Esc: back ', title_pos = 'center',
    }
  end

  local function hidden_popup()
    local config = vim.tbl_extend('force', helpers.popup_config(), { hide = true, noautocmd = true })
    return vim.api.nvim_open_win(state.transcript, false, config)
  end

  function helpers.restore_sidebar()
    local popup = state.transcript_win
    local expanded = helpers.expanded_folds(popup)
    local view
    if valid(popup) then
      vim.api.nvim_win_call(popup, function() view = vim.fn.winsaveview() end)
    end
    state.transcript_win, state.sidebar_win = state.sidebar_win, nil
    if valid(state.transcript_win) then
      M.decorate_chat(state.transcript_win, expanded)
      if view then vim.api.nvim_win_call(state.transcript_win, function() vim.fn.winrestview(view) end) end
    end
    if valid(popup) then vim.api.nvim_win_close(popup, true) end
    if valid(state.transcript_win) then vim.api.nvim_set_current_win(state.transcript_win) end
    helpers.update_header()
  end

  function M.toggle_popup()
    if not M.is_open() then return end
    if state.sidebar_win then return helpers.restore_sidebar() end
    local view
    vim.api.nvim_win_call(state.transcript_win, function() view = vim.fn.winsaveview() end)
    local popup = hidden_popup()
    state.sidebar_win, state.transcript_win = state.transcript_win, popup
    vim.wo[popup].wrap = true
    vim.wo[popup].linebreak = true
    M.decorate_chat(popup, helpers.expanded_folds(state.sidebar_win))
    vim.api.nvim_win_call(popup, function() vim.fn.winrestview(view) end)
    helpers.update_header()
    vim.api.nvim_win_set_config(popup, { hide = false })
    vim.api.nvim_set_current_win(popup)
  end

  function helpers.refresh_chat_folds()
    for _, win in ipairs({ state.transcript_win, state.sidebar_win }) do
      if valid(win) then helpers.update_fold_summaries(win) end
    end
  end

  vim.api.nvim_create_autocmd('VimResized', {
    group = state.slash_group,
    callback = function()
      if (state.sidebar_win or options.floating) and valid(state.transcript_win) then
        vim.api.nvim_win_set_config(state.transcript_win, helpers.popup_config())
        helpers.update_header()
      end
      helpers.refresh_chat_folds()
      helpers.draft_hint()
    end,
  })

  vim.api.nvim_create_autocmd('WinResized', {
    group = state.slash_group,
    callback = function()
      helpers.refresh_chat_folds()
      helpers.draft_hint()
    end,
  })

  function M.open(on_send, on_close)
    if M.is_open() then
      if not options.floating then require('codeit.ui.managed_tab').open() end
      helpers.focus_draft()
      return
    end
    M.close()
    if not options.floating then require('codeit.ui.managed_tab').open() end
    if not state.transcript or not vim.api.nvim_buf_is_valid(state.transcript) then
      state.transcript = scratch()
    end
    if options.floating then
      state.transcript_win = hidden_popup()
    else
      vim.cmd('botright 80vsplit')
      state.transcript_win = vim.api.nvim_get_current_win()
      helpers.configure_folds(state.transcript_win)
      vim.api.nvim_win_set_buf(state.transcript_win, state.transcript)
    end
    vim.api.nvim_win_call(state.transcript_win, helpers.disable_plugin_completion)
    vim.bo[state.transcript].completeopt = 'menuone,noselect'
    vim.wo[state.transcript_win].wrap = true
    vim.wo[state.transcript_win].linebreak = true
    vim.wo[state.transcript_win].number = false
    vim.wo[state.transcript_win].relativenumber = false
    vim.keymap.set('n', '<CR>', on_send, { buffer = state.transcript, desc = 'Send codeit message' })
    vim.keymap.set('n', '<Plug>(codeit-send)', on_send, { buffer = state.transcript, silent = true })
    if options.slash_commands == false then
      vim.keymap.set('i', '<C-s>', function()
        vim.cmd('stopinsert')
        on_send()
      end, { buffer = state.transcript, desc = 'Send codeit message' })
    else
      -- stopinsert inside a callback takes effect only after popup focus has changed.
      vim.keymap.set('i', '<C-s>', '<C-\\><C-n><Plug>(codeit-send)',
        { buffer = state.transcript, silent = true, desc = 'Send codeit message' })
    end
    if options.floating then
      vim.keymap.set('n', '<C-s>', on_send, { buffer = state.transcript, desc = 'Send codeit message' })
    end
    helpers.setup_completion()
    if not options.floating then
      vim.keymap.set({ 'n', 'i' }, '<C-g>', M.toggle_popup,
        { buffer = state.transcript, silent = true, desc = 'Toggle interactive chat popup' })
    end
    vim.keymap.set('n', '<Esc>', function()
      if options.floating then on_close()
      elseif state.sidebar_win then helpers.restore_sidebar() end
    end, { buffer = state.transcript, silent = true, desc = 'Return from chat popup' })
    vim.keymap.set('n', 'q', on_close, { buffer = state.transcript, desc = 'Close codeit chat' })
    M.decorate_chat(state.transcript_win)
    helpers.update_header()
    if options.floating then vim.api.nvim_win_set_config(state.transcript_win, { hide = false }) end
    helpers.focus_draft()
    return state.transcript_win, state.transcript
  end

  function M.close()
    helpers.stop_status_animation()
    helpers.close_palette()
    state.slash_hint, state.slash_error, state.dismissed = nil, nil, nil
    local active, sidebar = state.transcript_win, state.sidebar_win
    state.transcript_win, state.sidebar_win = nil, nil
    if valid(active) then vim.api.nvim_win_close(active, true) end
    if valid(sidebar) then vim.api.nvim_win_close(sidebar, true) end
    if state.transcript and vim.api.nvim_buf_is_valid(state.transcript) then
      vim.api.nvim_buf_clear_namespace(state.transcript, state.ui_ns, 0, -1)
    end
    if not options.floating then require('codeit.ui.managed_tab').leave() end
  end

  -- Ignore close events from an earlier session if the chat has since reopened.
  vim.api.nvim_create_autocmd('WinClosed', {
    group = state.slash_group,
    callback = function(args)
      local closed = tonumber(args.match)
      if closed ~= state.transcript_win and closed ~= state.sidebar_win then return end
      vim.schedule(function()
        if closed == state.sidebar_win then
          M.close()
        elseif closed == state.transcript_win then
          if valid(state.sidebar_win) then helpers.restore_sidebar() else M.close() end
        end
      end)
    end,
  })
end

return M
