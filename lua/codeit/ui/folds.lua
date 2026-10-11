local M = {}
local saved_foldopen, guarded_win

local function release_foldopen(win)
  if guarded_win ~= win then return end
  vim.o.foldopen = saved_foldopen
  saved_foldopen, guarded_win = nil, nil
end

function M.attach(api, state, options, helpers)
  local M = api
  function helpers.guard_chat_foldopen()
    local win = vim.api.nvim_get_current_win()
    if (win ~= state.transcript_win and win ~= state.sidebar_win)
      or vim.api.nvim_get_current_buf() ~= state.transcript then return end
    -- foldopen is global: suppress it only while the user is in a chat view.
    if saved_foldopen == nil then saved_foldopen = vim.o.foldopen end
    guarded_win, vim.o.foldopen = win, ''
  end

  helpers.release_chat_foldopen = release_foldopen
  vim.api.nvim_create_autocmd({ 'WinEnter', 'BufEnter' }, {
    group = state.slash_group, callback = helpers.guard_chat_foldopen,
  })
  vim.api.nvim_create_autocmd({ 'WinLeave', 'BufLeave' }, {
    group = state.slash_group,
    callback = function() release_foldopen(vim.api.nvim_get_current_win()) end,
  })
  -- Measure activity bodies in a hidden copy without exposing them in the chat.
  local function with_fold_probe(win, callback)
    return vim.api.nvim_win_call(win, function()
      local width = vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff
      local probe = vim.api.nvim_open_win(vim.api.nvim_win_get_buf(win), false, {
        relative = 'editor', row = 0, col = 0, width = math.max(1, width), height = 1,
        hide = true, noautocmd = true, focusable = false, style = 'minimal',
      })
      vim.w[probe].codeit_fold_levels = vim.w[win].codeit_fold_levels
      vim.wo[probe].foldmethod = 'manual'
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
      for _, fold in ipairs(state.section_folds) do
        local height = vim.api.nvim_win_text_height(probe, {
          start_row = fold.first - 1 + fold.padding,
          end_row = fold.last - 1 - fold.padding,
        })
        summaries[tostring(fold.first)] = { preview = fold.preview, count = height.all - height.fill }
      end
      return summaries
    end)
    vim.w[win].codeit_fold_summaries = summaries
  end

  function M.tool_foldtext()
    local summary = (vim.w.codeit_fold_summaries or {})[tostring(vim.v.foldstart)]
    if not summary then return '  Activity … (za: expand)' end
    local suffix = ' … (' .. summary.count .. ' lines · za: expand)'
    local preview = summary.preview:gsub('\t', ' ')
    local width = math.max(0, vim.api.nvim_win_get_width(0) - vim.fn.strdisplaywidth(suffix) - 2)
    preview = vim.fn.strcharpart(preview, 0, width)
    while vim.fn.strdisplaywidth(preview) > width do
      preview = vim.fn.strcharpart(preview, 0, vim.fn.strchars(preview) - 1)
    end
    return '  ' .. preview .. suffix
  end

  local function recompute_folds(win)
    vim.api.nvim_win_call(win, function()
      local view = vim.fn.winsaveview()
      vim.cmd('noautocmd normal! zX')
      vim.fn.winrestview(view)
    end)
  end

  -- Fold ranges are available before buffer updates, without deleting live folds.
  function helpers.configure_folds(win)
    local levels, summaries = {}, {}
    for _, fold in ipairs(state.section_folds) do
      for row = fold.first, fold.last do levels[tostring(row)] = 1 end
      levels[tostring(fold.first)], levels[tostring(fold.last)] = '>1', '<1'
      summaries[tostring(fold.first)] = {
        preview = fold.preview, count = fold.last - fold.first + 1 - 2 * fold.padding,
      }
    end
    local expr = 'get(get(w:, "codeit_fold_levels", {}), v:lnum, 0)'
    local changed = vim.wo[win].foldexpr ~= expr or vim.wo[win].foldmethod ~= 'expr'
      or not vim.deep_equal(vim.w[win].codeit_fold_levels, levels) or vim.wo[win].foldlevel ~= 0
    -- Publish safe summaries before a rebuild can request foldtext. Wrapped line
    -- counts are measured after the reserved rows have their final text.
    vim.w[win].codeit_fold_summaries = summaries
    vim.w[win].codeit_fold_levels = levels
    -- Recomputing must start closed, even after zR or a manual close at a higher
    -- foldlevel. Explicit expansions are restored separately by section key.
    vim.wo[win].foldlevel = 0
    helpers.guard_chat_foldopen()
    vim.wo[win].foldexpr = expr
    vim.wo[win].foldmethod = 'expr'
    vim.wo[win].foldenable = true
    vim.wo[win].foldminlines = 0
    vim.wo[win].foldtext = 'v:lua.require("codeit.ui").tool_foldtext()'
    if not changed then return end
    -- Insert mode defers expression-fold updates; materialize reserved ranges
    -- before restoring expansion state or writing their activity text.
    recompute_folds(win)
  end

  function helpers.restore_folds(win, expanded)
    vim.api.nvim_win_call(win, function()
      local view = vim.fn.winsaveview()
      local lazyredraw = vim.o.lazyredraw
      vim.o.lazyredraw = true
      local ok, err = pcall(function()
        if expanded then
          for _, section in ipairs(state.section_folds) do
            local open = expanded.sections and expanded.sections[section.key]
            if open and vim.fn.foldclosed(section.first) ~= -1 then
              vim.cmd('noautocmd ' .. section.first .. 'foldopen')
            end
            if not open and vim.fn.foldclosed(section.first) == -1 then
              vim.cmd('noautocmd ' .. section.first .. 'foldclose')
            end
          end
        end
        vim.fn.winrestview(view)
      end)
      vim.o.lazyredraw = lazyredraw
      if not ok then error(err) end
    end)
  end

  function helpers.sync_fold_boundaries(win, expanded)
    vim.api.nvim_win_call(win, function()
      for _, fold in ipairs(state.section_folds) do
        -- Insert-mode text writes can leave a cached boundary one row short.
        -- Rebuild only when it drifted, then restore this view's expansion state.
        if vim.fn.foldlevel(fold.first) ~= 1 or vim.fn.foldlevel(fold.last) ~= 1 then
          recompute_folds(win)
          helpers.restore_folds(win, expanded)
          return
        end
      end
    end)
  end

  --- Configure folds and role styling in both interactive and read-only chat windows.
  function M.decorate_chat(win, expanded, folds_ready)
    local buf = vim.api.nvim_win_get_buf(win)
    if not folds_ready then
      helpers.configure_folds(win)
      helpers.restore_folds(win, expanded)
    end
    helpers.update_fold_summaries(win)
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
      vim.api.nvim_win_call(win, function()
        for _, fold in ipairs(state.section_folds) do
          if vim.fn.foldlevel(fold.first) > 0 and vim.fn.foldclosed(fold.first) == -1 then
            expanded.sections[fold.key] = true
          end
        end
      end)
    end
    return expanded
  end
end

return M
