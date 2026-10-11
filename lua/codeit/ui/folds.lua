local M = {}

function M.attach(api, state, options, helpers)
  local M = api
  -- A same-buffer window inherits the source's manual folds, including child state.
  -- Inspect and measure that hidden copy without ever exposing live activity bodies.
  local function with_fold_probe(win, callback)
    return vim.api.nvim_win_call(win, function()
      local width = vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff
      local probe = vim.api.nvim_open_win(vim.api.nvim_win_get_buf(win), false, {
        relative = 'editor', row = 0, col = 0, width = math.max(1, width), height = 1,
        hide = true, noautocmd = true, focusable = false, style = 'minimal',
      })
      local ok, result = pcall(vim.api.nvim_win_call, probe, function() return callback(probe) end)
      vim.cmd('noautocmd call nvim_win_close(' .. probe .. ', v:true)')
      if not ok then error(result) end
      return result
    end)
  end

  function helpers.update_fold_summaries(win)
    local summaries = with_fold_probe(win, function(probe)
      vim.wo[probe].foldenable = false
      local summaries = {}
      for _, folds in ipairs({ state.tool_folds, state.section_folds }) do
        for _, fold in ipairs(folds) do
          local height = vim.api.nvim_win_text_height(probe, {
            start_row = fold.first - 1 + fold.padding,
            end_row = fold.last - 1 - fold.padding,
          })
          summaries[tostring(fold.first)] = { preview = fold.preview, count = height.all - height.fill }
        end
      end
      return summaries
    end)
    vim.w[win].codeit_fold_summaries = summaries
  end

  function M.tool_foldtext()
    local summary = (vim.w.codeit_fold_summaries or {})[tostring(vim.v.foldstart)]
    if not summary then return vim.fn.getline(vim.v.foldstart) end
    local suffix = ' … (' .. summary.count .. ' lines · za: expand)'
    local preview = summary.preview:gsub('\t', ' ')
    local width = math.max(0, vim.api.nvim_win_get_width(0) - vim.fn.strdisplaywidth(suffix) - 2)
    preview = vim.fn.strcharpart(preview, 0, width)
    while vim.fn.strdisplaywidth(preview) > width do
      preview = vim.fn.strcharpart(preview, 0, vim.fn.strchars(preview) - 1)
    end
    return '  ' .. preview .. suffix
  end

  --- Configure folds and role styling in both interactive and read-only chat windows.
  function M.decorate_chat(win, expanded)
    local buf = vim.api.nvim_win_get_buf(win)
    vim.wo[win].foldmethod = 'manual'
    vim.wo[win].foldenable = true
    vim.wo[win].foldlevel = 0
    vim.wo[win].foldminlines = 0
    vim.wo[win].foldtext = 'v:lua.require("codeit.ui").tool_foldtext()'
    vim.api.nvim_win_call(win, function()
      local view = vim.fn.winsaveview()
      vim.cmd('silent! normal! zE')
      for _, folds in ipairs({ state.tool_folds, state.section_folds }) do
        for _, fold in ipairs(folds) do
          vim.cmd(fold.first .. ',' .. fold.last .. 'fold')
          local fold_state = folds == state.section_folds and expanded and expanded.sections or expanded
          if fold_state and fold_state[fold.key] then vim.cmd(fold.first .. 'foldopen') end
        end
      end
      helpers.update_fold_summaries(win)
      vim.fn.winrestview(view)
    end)
    vim.api.nvim_buf_clear_namespace(buf, state.ui_ns, 0, -1)
    if buf == state.transcript then state.draft_hint_id = nil end
    for _, mark in ipairs(state.role_marks) do
      vim.api.nvim_buf_set_extmark(buf, state.ui_ns, mark.row, 0, {
        end_col = #mark.text, hl_group = mark.group, priority = 200,
      })
    end
    local turns = {}
    for _, mark in ipairs(state.role_marks) do
      if mark.group == 'CodeitUser' then turns[#turns + 1] = mark.row + 1 end
    end
    local function move_turn(direction)
      local row = vim.api.nvim_win_get_cursor(0)[1]
      local target, remaining = nil, vim.v.count1
      local first = direction == 1 and 1 or #turns
      local last = direction == 1 and #turns or 1
      for index = first, last, direction do
        if (turns[index] - row) * direction > 0 then
          target = turns[index]
          remaining = remaining - 1
          if remaining == 0 then break end
        end
      end
      if target then vim.api.nvim_win_set_cursor(0, { target, 0 }) end
    end
    vim.keymap.set('n', '{', function() move_turn(-1) end,
      { buffer = buf, silent = true, desc = 'Previous chat turn' })
    vim.keymap.set('n', '}', function() move_turn(1) end,
      { buffer = buf, silent = true, desc = 'Next chat turn' })
    if buf == state.transcript then helpers.draft_hint() end
  end

  function helpers.expanded_folds(win)
    local expanded = { sections = {} }
    if win and vim.api.nvim_win_is_valid(win) then
      with_fold_probe(win, function()
        -- Expose children only in the hidden copy to retain their independent state.
        for _, fold in ipairs(state.section_folds) do
          if vim.fn.foldlevel(fold.first) > 0 then
            if vim.fn.foldclosed(fold.first) == fold.first then
              vim.cmd(fold.first .. 'foldopen')
            else
              expanded.sections[fold.key] = true
            end
          end
        end
        for _, fold in ipairs(state.tool_folds) do
          if vim.fn.foldlevel(fold.first) > 0 and vim.fn.foldclosed(fold.first) == -1 then
            expanded[fold.key] = true
          end
        end
      end)
    end
    return expanded
  end
end

return M
