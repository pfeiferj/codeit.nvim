local M = {}

function M.attach(api, state, options, helpers)
  local M = api
  local markdown = require('codeit.ui.markdown')
  local usage_format = require('codeit.usage_format')
  local function valid(win) return win and vim.api.nvim_win_is_valid(win) end
  local function tool_output_language(name, content)
    if name == 'run_command' then return 'bash' end
    if pcall(vim.json.decode, content) then return 'json' end
    if name == 'git_diff' then return 'diff' end
    return 'text'
  end

  local function follow_prompt(win, view, prompt, previous_prompt, new_turn)
    vim.api.nvim_win_call(win, function()
      local cursor = vim.api.nvim_win_get_cursor(win)
      local height = vim.api.nvim_win_text_height(win, {
        start_row = prompt - 1, end_row = cursor[1] - 1,
      }).all
      local scrolloff = vim.wo[win].scrolloff
      vim.wo[win].scrolloff = 0
      -- Let Neovim account for wrapped rows and virtual lines when the turn overflows.
      vim.cmd('normal! zb')
      if height <= vim.api.nvim_win_get_height(win) then
        local topline = prompt
        if not new_turn and previous_prompt then
          topline = math.max(1, math.min(prompt, view.topline + prompt - previous_prompt))
        end
        local bottom = vim.fn.winsaveview()
        bottom.topline, bottom.topfill, bottom.skipcol = topline, 0, 0
        vim.fn.winrestview(bottom)
      end
      vim.wo[win].scrolloff = scrolloff
    end)
  end

  local function update_lines(lines)
    local old = vim.api.nvim_buf_get_lines(state.transcript, 0, state.draft_start, false)
    local hunks = vim.diff(table.concat(old, '\n') .. '\n', table.concat(lines, '\n') .. '\n',
      { result_type = 'indices', algorithm = 'minimal' })
    -- Apply from the bottom so unchanged activity and draft rows keep their folds and marks.
    for index = #hunks, 1, -1 do
      local first, count, next_first, next_count = unpack(hunks[index])
      local replacement = vim.list_slice(lines, next_first, next_first + next_count - 1)
      if count == 0 then
        vim.api.nvim_buf_set_lines(state.transcript, first, first, false, replacement)
      elseif next_count == 0 then
        vim.api.nvim_buf_set_lines(state.transcript, first - 1, first + count - 1, false, {})
      else
        vim.api.nvim_buf_set_text(state.transcript, first - 1, 0, first + count - 2,
          #old[first + count - 1], replacement)
      end
    end
  end

  local function render(messages, status, provider, model, billing, command_results, can_send, turn_costs, last_agent_activity)
    local existing_tools = {}
    for _, fold in ipairs(state.tool_folds) do existing_tools[fold.key] = true end
    local costs_by_message = {}
    for _, turn in ipairs(turn_costs or {}) do costs_by_message[turn.first] = turn end
    local views = {}
    for _, win in ipairs({ state.transcript_win, state.sidebar_win }) do
      if valid(win) then
        local cursor = vim.api.nvim_win_get_cursor(win)
        vim.api.nvim_win_call(win, function()
          views[win] = { view = vim.fn.winsaveview(), cursor = cursor,
            draft_row = cursor[1] > state.draft_start and cursor[1] - state.draft_start or nil }
        end)
      end
    end
    local previous_prompt, previous_index = state.latest_prompt_row, state.latest_prompt_index
    state.latest_prompt_row, state.latest_prompt_index = nil, nil
    if not options.floating then require('codeit.ui.assistant_pane').set_messages(messages) end
    local active_expanded = helpers.expanded_folds(state.transcript_win)
    local sidebar_expanded = helpers.expanded_folds(state.sidebar_win)
    state.tool_folds, state.section_folds, state.role_marks = {}, {}, {}
    state.can_send_message = can_send ~= false
    state.draft_status = status
    state.last_agent_activity = last_agent_activity
    local lines = options.header and vim.deepcopy(options.header)
      or { '# Codeit (' .. provider .. ': ' .. model .. ')' }
    if billing then table.insert(lines, '> ' .. billing) end
    state.billing_line = billing
    table.insert(lines, '')
    -- Results belong to a message boundary, not to the moving draft heading.
    local results_by_message = {}
    for _, result in ipairs(command_results or {}) do
      local index = result.after_message
      results_by_message[index] = results_by_message[index] or {}
      table.insert(results_by_message[index], result)
    end
    local section
    local function finish_section()
      if not section then return end
      section.last = #lines
      section.preview = 'Activity · ' .. section.count .. ' items'
      state.section_folds[#state.section_folds + 1] = section
      section = nil
    end
    local function start_item(key, label)
      if not section then
        section = { first = #lines + 1, key = key, padding = 0, count = 0 }
        table.insert(lines, '**Activity**')
        table.insert(lines, '')
      end
      section.count = section.count + 1
      local first = #lines + 1
      state.role_marks[#state.role_marks + 1] = { row = #lines, text = label, group = 'CodeitTool' }
      table.insert(lines, label)
      table.insert(lines, '')
      return first
    end
    local function finish_item(first, key, preview)
      state.tool_folds[#state.tool_folds + 1] = { first = first, last = #lines, key = key,
        preview = preview or lines[first], padding = 0 }
      table.insert(lines, '')
    end
    local function render_results(index)
      for _, result in ipairs(results_by_message[index] or {}) do
        local first = start_item(result, '## Command: `' .. result.command .. '`')
        vim.list_extend(lines, vim.split(result.output, '\n', { plain = true }))
        finish_item(first, result)
      end
    end
    render_results(0)
    local tool_names = {}
    for index, message in ipairs(messages) do
      if message.role ~= 'system' then
        local content = message.content
        if type(content) == 'table' then
          local parts = {}
          for _, part in ipairs(content) do
            if part.type == 'text' then table.insert(parts, part.text or '') end
          end
          content = table.concat(parts, '\n')
        end
        if message.role == 'assistant' then
          local reasoning = {}
          local function add_text(text)
            if type(text) == 'string' and text ~= '' then reasoning[#reasoning + 1] = text end
          end
          for _, detail in ipairs(message.reasoning_details or {}) do
            add_text(detail.text)
            add_text(detail.summary)
          end
          for _, item in ipairs(message._copilot_reasoning or message._codex_reasoning or {}) do
            for _, part in ipairs(item.summary or {}) do add_text(part.text) end
          end
          if #reasoning > 0 then
            local key = message.reasoning_details or message._copilot_reasoning or message._codex_reasoning
            local first = start_item(key, '**Reasoning**')
            vim.list_extend(lines, vim.split(table.concat(reasoning, '\n'), '\n', { plain = true }))
            finish_item(first, key)
          end
        end
        if message.role == 'user' or (message.role == 'assistant' and type(content) == 'string' and content ~= '') then
          finish_section()
          if message.role == 'user' then
            table.insert(lines, '---')
            table.insert(lines, '')
          end
          if message.role == 'user' then
            state.latest_prompt_row, state.latest_prompt_index = #lines + 1, index
          end
          local label = message.role == 'user' and '**You**' or ('**' .. (options.assistant_label or 'Assistant') .. '**')
          if message.role == 'user' and turn_costs then
            local turn = costs_by_message[index]
            label = label .. ' · Turn cost: ' .. (turn and usage_format.cost(turn.cost, turn.missing_cost > 0) or 'unknown')
          end
          state.role_marks[#state.role_marks + 1] = { row = #lines, text = label,
            group = message.role == 'user' and 'CodeitUser' or 'CodeitAssistant' }
          table.insert(lines, label)
          table.insert(lines, '')
          if type(content) == 'string' and content ~= '' then
            vim.list_extend(lines, vim.split(content, '\n', { plain = true }))
          end
          table.insert(lines, '')
        elseif message.role ~= 'assistant' then
          local name = message.name or tool_names[message.tool_call_id] or message.tool_call_id or ''
          local label = message.role == 'tool' and ('**Tool: ' .. name .. '**') or ('**' .. message.role .. '**')
          local first = start_item(message, label)
          if type(content) == 'string' and content ~= '' then
            vim.list_extend(lines, markdown.fence(content, tool_output_language(name, content)))
          end
          finish_item(first, message, label .. (type(content) == 'string' and content ~= ''
            and (' · ' .. vim.split(content, '\n', { plain = true })[1]) or ''))
        end
        for _, call in ipairs(message.tool_calls or {}) do
          local fn = call['function'] or {}
          local name = fn.name or 'unknown tool'
          if call.id then tool_names[call.id] = name end
          local first = start_item(call, '*Calling `' .. name .. '`…*')
          local input = fn.arguments
          if type(input) == 'string' and input ~= '' then
            local ok, decoded = pcall(vim.json.decode, input)
            if ok then input = require('codeit.tools.approval.format').pretty_json(decoded) end
            vim.list_extend(lines, markdown.fence(input, ok and 'json' or 'text'))
          end
          finish_item(first, call)
        end
      end
      render_results(index)
    end
    finish_section()
    state.chat_lines = vim.deepcopy(lines)
    if not state.transcript or not vim.api.nvim_buf_is_valid(state.transcript) then return end
    table.insert(lines, '')
    table.insert(lines, '## ' .. (options.draft_label or 'Message'))
    table.insert(lines, '')
    local pending = {}
    local structure = vim.list_slice(lines)
    if next(views) then
      for _, fold in ipairs(state.tool_folds) do
        local body = vim.list_slice(lines, fold.first + 1, fold.last)
        if not existing_tools[fold.key] then
          pending[#pending + 1] = { fold = fold, body = body }
          for row = fold.first + 1, fold.last do structure[row] = '' end
        end
      end
    end
    for win in pairs(views) do helpers.configure_folds(win) end
    update_lines(structure)
    state.draft_start = #lines
    if valid(state.transcript_win) then M.decorate_chat(state.transcript_win, active_expanded) end
    if valid(state.sidebar_win) then M.decorate_chat(state.sidebar_win, sidebar_expanded) end
    for _, item in ipairs(pending) do
      local fold = item.fold
      vim.api.nvim_buf_set_text(state.transcript, fold.first, 0, fold.last - 1, 0, item.body)
    end
    if #pending > 0 then
      for win in pairs(views) do helpers.update_fold_summaries(win) end
    end
    helpers.update_header()
    for win, view_state in pairs(views) do
      if view_state.draft_row then
        vim.api.nvim_win_set_cursor(win, {
          math.min(state.draft_start + view_state.draft_row, vim.api.nvim_buf_line_count(state.transcript)), view_state.cursor[2],
        })
        if state.latest_prompt_row then
          follow_prompt(win, view_state.view, state.latest_prompt_row, previous_prompt, state.latest_prompt_index ~= previous_index)
        end
      else
        vim.api.nvim_win_call(win, function() vim.fn.winrestview(view_state.view) end)
      end
    end
  end

  function M.render(...)
    local lazyredraw = vim.o.lazyredraw
    vim.o.lazyredraw = true
    local ok, err = pcall(render, ...)
    vim.o.lazyredraw = lazyredraw
    if not ok then error(err) end
  end

  --- A read-only chat preview excludes the editable message draft.
  function M.chat_lines()
    return vim.deepcopy(state.chat_lines)
  end
end

return M
