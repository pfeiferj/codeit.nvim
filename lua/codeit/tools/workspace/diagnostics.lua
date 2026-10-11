local M = {}
local spec = require('codeit.tools.spec')
local paths = require('codeit.tools.workspace.paths')
local buffers = require('codeit.file_buffer')
local resolve, within = paths.resolve, paths.within

M.specs = {
  spec('get_diagnostics', 'Get existing LSP/linter diagnostics for loaded workspace files (max 200). Omit path/empty path for all. wait_ms (0-5000) optionally waits for a matching DiagnosticChanged event, not a guaranteed complete/fresh check. With wait_ms>0 returns diagnostics, updated, timed_out, waited_ms; otherwise returns the existing array. Never runs tests or starts a linter; empty results are not proof of success.', {
    path = { type = 'string', description = 'Optional workspace path; empty returns workspace diagnostics' },
    wait_ms = { type = 'integer', minimum = 0, maximum = 5000, description = 'Wait for a diagnostic update, at most this many milliseconds; default 0' },
  }),
}

function M.execute(name, args, done, active, approve, reads, prepare, source, origin)
  local base = paths.root()
  if not base then return done('Error: workspace does not exist') end
  if name == 'get_diagnostics' then
    local filter
    if args.path ~= nil and args.path ~= '' then
      local err
      filter, err = resolve(args.path, true)
      if not filter then return done('Error: ' .. err) end
    end
    local function eligible(id)
      if not buffers.valid(id) or vim.bo[id].buftype ~= '' then return false end
      local path = vim.api.nvim_buf_get_name(id)
      return path ~= '' and resolve(path, true) and within(path, base) and (not filter or path == filter)
    end
    local function collect()
      local items, truncated = {}, false
      for _, id in ipairs(vim.api.nvim_list_bufs()) do
        if eligible(id) then
          for _, diagnostic in ipairs(vim.diagnostic.get(id)) do
            if #items == 200 then truncated = true; break end
            items[#items + 1] = { path = vim.api.nvim_buf_get_name(id), line = diagnostic.lnum + 1, column = diagnostic.col + 1,
              severity = diagnostic.severity, message = diagnostic.message, source = diagnostic.source }
          end
        end
      end
      return items, truncated
    end
    if not args.wait_ms or args.wait_ms == 0 then
      local items = collect()
      return done(vim.json.encode(items))
    end
    local started, finished = vim.uv.hrtime(), false
    local event, timer
    local function cleanup()
      if event then pcall(vim.api.nvim_del_autocmd, event) end
      if timer then timer:stop(); timer:close() end
    end
    local function finish(updated)
      if finished then return end
      finished = true
      cleanup()
      if active and not active() then return end
      local ok, items, truncated = pcall(collect)
      if not ok then return done('Error: diagnostics collection failed: ' .. tostring(items)) end
      done(vim.json.encode({ diagnostics = items, truncated = truncated, updated = updated, timed_out = not updated,
        waited_ms = math.floor((vim.uv.hrtime() - started) / 1000000),
        note = 'Observed updates are not proof of a complete or fresh check; no tests or linters were run.' }))
    end
    event = vim.api.nvim_create_autocmd('DiagnosticChanged', { callback = function(event_args)
      if not finished and eligible(event_args.buf) then vim.schedule(function() finish(true) end) end
    end })
    timer = vim.uv.new_timer()
    timer:start(10, 10, vim.schedule_wrap(function()
      if finished then return end
      if active and not active() then finished = true; cleanup(); return end
      if (vim.uv.hrtime() - started) / 1000000 >= args.wait_ms then finish(false) end
    end))
    return
  end
  done('Error: unknown tool ' .. tostring(name))
end

return M
