local M = {}
local kitty = require('codeit.ui.kitty')
local worker = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p'):gsub('%.lua$', '.js')

--- Snapshot all unfolded transcript rows, not just the current screenful.
--- Read folds in the source window: sidebar and popup can have different folds.
function M.snapshot(win, last)
  return vim.api.nvim_win_call(win, function()
    local buf = vim.api.nvim_win_get_buf(win)
    local source = vim.api.nvim_buf_get_lines(buf, 0, last, false)
    local lines, row = {}, 1
    while row <= #source do
      local finish = vim.fn.foldclosedend(row)
      if finish ~= -1 then
        lines[#lines + 1] = ''
        row = finish + 1
      else
        lines[#lines + 1] = source[row]
        row = row + 1
      end
    end
    return table.concat(lines, '\n')
  end)
end

function M.scroll_offset(offset, delta, rows, height)
  return math.max(0, math.min(math.max(0, rows - height), offset + delta))
end

function M.attach(api, state, options, helpers)
  local preview
  local function valid(win) return win and vim.api.nvim_win_is_valid(win) end
  local function warn(message)
    vim.notify('codeit: ' .. tostring(message), vim.log.levels.WARN)
  end

  function api.close_rendered_chat()
    local old = preview
    if not old then return end
    preview = nil
    if old.reveal_timer and not old.reveal_timer:is_closing() then
      old.reveal_timer:stop()
      old.reveal_timer:close()
    end
    if old.job then pcall(function() old.job:kill(15) end) end
    if old.terminal then
      if old.uploaded then pcall(kitty.delete, old.terminal, old.image_id) end
      old.terminal:close()
    end
    if old.group then pcall(vim.api.nvim_del_augroup_by_id, old.group) end
    if valid(old.win) then vim.api.nvim_win_close(old.win, true) end
    if old.buf and vim.api.nvim_buf_is_valid(old.buf) then
      vim.api.nvim_buf_delete(old.buf, { force = true })
    end
    -- A running worker owns cleanup until its exit callback (including after kill).
    if not old.job and old.path then vim.fn.delete(old.path) end
  end

  function api.render_chat()
    local current = vim.api.nvim_get_current_win()
    local source = current == state.sidebar_win and current or state.transcript_win
    if not valid(source) then return warn('Open the chat before rendering it.') end
    if vim.fn.executable('node') ~= 1 then return warn('Rendered chat requires Node.js; see README.') end
    local markdown = M.snapshot(source, #state.chat_lines)
    api.close_rendered_chat()
    local opened, terminal = pcall(kitty.open)
    if not opened then return warn(terminal) end
    local p = { offset = 0, path = vim.fn.tempname() .. '.png', terminal = terminal,
      image_id = math.random(1, 2147483647) }
    preview = p
    p.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[p.buf].bufhidden = 'wipe'
    vim.bo[p.buf].swapfile = false
    vim.api.nvim_buf_set_lines(p.buf, 0, -1, false, { 'Rendering chat locally…' })
    vim.bo[p.buf].modifiable = false
    local width, height = math.max(1, vim.o.columns - 4), math.max(1, vim.o.lines - 6)
    p.win = vim.api.nvim_open_win(p.buf, true, {
      relative = 'editor', row = 1, col = 1, width = width, height = height,
      style = 'minimal', border = 'rounded',
      title = ' Rendered chat · j/k, Ctrl-D/U, gg/G · q: close ', title_pos = 'center',
    })
    vim.wo[p.win].wrap = false
    vim.wo[p.win].winblend = 0
    vim.wo[p.win].cursorline = false
    p.group = vim.api.nvim_create_augroup('codeit_render_' .. p.buf, { clear = true })
    local function draw(delta)
      if preview ~= p or not p.image or not valid(p.win) then return end
      p.offset = M.scroll_offset(p.offset, delta, p.rows, vim.api.nvim_win_get_height(p.win))
      -- Flush the loading text/float before placing graphics at its physical
      -- screen position. Reuse the same placement ID when the crop changes.
      vim.cmd('redraw')
      local rendered, err = pcall(kitty.place, p.terminal, p.image_id, p.win, p.offset, p.image, p.size)
      if not rendered then api.close_rendered_chat(); warn(err) end
    end
    local function map(key, callback)
      vim.keymap.set('n', key, callback, { buffer = p.buf, silent = true, nowait = true })
    end
    for _, key in ipairs({ 'q', '<Esc>', '<C-g>' }) do map(key, api.close_rendered_chat) end
    for _, key in ipairs({ 'j', '<Down>' }) do map(key, function() draw(vim.v.count1) end) end
    for _, key in ipairs({ 'k', '<Up>' }) do map(key, function() draw(-vim.v.count1) end) end
    map('<ScrollWheelDown>', function() draw(3) end)
    map('<ScrollWheelUp>', function() draw(-3) end)
    for _, key in ipairs({ '<C-d>', '<PageDown>', '<Space>' }) do map(key, function() draw(math.max(1, math.floor(height / 2))) end) end
    for _, key in ipairs({ '<C-u>', '<PageUp>' }) do map(key, function() draw(-math.max(1, math.floor(height / 2))) end) end
    map('gg', function() draw(-math.huge) end)
    map('G', function() draw(math.huge) end)
    vim.api.nvim_create_autocmd('WinClosed', {
      group = p.group, pattern = tostring(p.win), callback = api.close_rendered_chat,
    })
    vim.api.nvim_create_autocmd({ 'BufWipeout', 'BufLeave', 'WinLeave' }, {
      group = p.group, buffer = p.buf, callback = api.close_rendered_chat,
    })
    -- Closing on resize avoids silently rescaling text or showing a stale crop.
    vim.api.nvim_create_autocmd({ 'VimResized', 'VimLeavePre', 'VimSuspend', 'FocusLost' }, {
      group = p.group, callback = api.close_rendered_chat,
    })
    local function start(size, size_error)
      if preview ~= p then return end
      if not size then api.close_rendered_chat(); return warn(size_error) end
      p.size = size
      local modules = vim.g.codeit_render_node_modules
        or (vim.fn.stdpath('data') .. '/codeit/render/node_modules')
      local started, job = pcall(vim.system, { 'node', worker }, {
        text = true, timeout = 60000, env = { NODE_PATH = modules },
        stdin = vim.json.encode({ markdown = markdown, output = p.path,
          width = math.max(1, math.floor(width * size.cell_width)),
          font_size = math.max(14, math.floor(size.cell_height * 0.8)), dark = vim.o.background == 'dark' }),
      }, function(result)
        vim.schedule(function()
          p.job = nil
          if preview ~= p then vim.fn.delete(p.path); return end
          if result.code ~= 0 then
            api.close_rendered_chat()
            return warn((result.stderr or '') ~= '' and result.stderr or 'Markdown renderer failed or timed out.')
          end
          local loaded, err = pcall(function()
            p.image = vim.json.decode(result.stdout)
            assert(type(p.image) == 'table' and type(p.image.width) == 'number'
              and type(p.image.height) == 'number' and p.image.width > 0 and p.image.height > 0,
              'Renderer returned invalid image dimensions')
            p.rows = math.ceil(p.image.height / size.cell_height)
            p.uploaded = true -- Also clean up a partially failed upload.
            kitty.upload(p.terminal, p.image_id, p.path)
            vim.fn.delete(p.path)
            vim.bo[p.buf].modifiable = true
            vim.api.nvim_buf_set_lines(p.buf, 0, -1, false, { '' })
            vim.bo[p.buf].modifiable = false
            draw(0)
            if preview == p then
              -- With direct TTY output, :redraw queues UI updates but does not
              -- wait for a separate TUI to paint them. Its initial clear can
              -- land after our placement. Reassert the same crop once after
              -- that first paint; do not upload again or reset scroll position.
              p.reveal_timer = vim.defer_fn(function()
                p.reveal_timer = nil
                draw(0) -- draw checks instance/window validity before writing.
              end, 75)
            end
          end)
          if not loaded then api.close_rendered_chat(); warn(err) end
        end)
      end)
      if not started then api.close_rendered_chat(); return warn(job) end
      p.job = job
    end
    local measured, err = pcall(function() terminal:measure(start) end)
    if not measured then api.close_rendered_chat(); warn(err) end
  end
end

return M
