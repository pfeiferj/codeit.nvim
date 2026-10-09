local M = {}

-- Stream output instead of retaining an unbounded vim.system capture. Each process
-- has its own session on Unix so cancellation also reaches ordinary descendants.
function M.run(argv, cwd, done, active, opts)
  opts = opts or {}
  local finished, stopping, observer_error = false, false, nil
  local stdout, stderr, bytes, truncated = {}, {}, 0, false
  local handle, timer, deliver
  local function collect(target, chunk)
    if not chunk then return end
    local remaining = math.max(0, (opts.max_bytes or 20000) - bytes)
    if #chunk > remaining then truncated = true end
    chunk = chunk:sub(1, remaining)
    bytes = bytes + #chunk
    if chunk ~= '' then target[#target + 1] = chunk end
  end
  local function signal(number)
    if not handle then return end
    if vim.fn.has('unix') == 1 and handle.pid then
      pcall(vim.uv.kill, -handle.pid, number)
    end
    pcall(handle.kill, handle, number)
  end
  local function stop(reason)
    if finished or stopping then return end
    stopping = reason
    signal(15)
    vim.defer_fn(function()
      -- Descendants may still be alive after the direct child has exited.
      signal(9)
      if not finished then
        finished = true
        if timer then timer:stop(); timer:close() end
        if not active or active() then
          deliver({ code = -1, stdout = table.concat(stdout), stderr = table.concat(stderr),
            truncated = truncated, timed_out = reason == 'timeout' })
        elseif opts.cleanup then opts.cleanup() end
      end
    end, opts.kill_after_ms or 1000)
  end
  deliver = function(result)
    local ok, err = pcall(done, result)
    if not ok then
      -- Surface observer errors as a tool result instead of leaving its caller busy.
      pcall(done, { code = -1, stdout = '', stderr = 'Error: process callback failed: ' .. tostring(err) })
    end
    if opts.cleanup then opts.cleanup() end
  end
  local ok, err = pcall(function()
    handle = vim.system(argv, {
      cwd = cwd, text = true, detached = vim.fn.has('unix') == 1,
      stdout = function(error, chunk)
        if error then collect(stderr, tostring(error)) end
        if opts.on_stdout then
          -- The observer runs on the main loop, in order before completion.
          vim.schedule(function()
            if not finished then
              local success, failure = pcall(opts.on_stdout, chunk or '')
              if not success then observer_error = tostring(failure); collect(stderr, observer_error); stop('error') end
            end
          end)
        else
          collect(stdout, chunk)
        end
      end,
      stderr = function(error, chunk)
        collect(stderr, error and tostring(error) or chunk)
      end,
    }, function(result)
      vim.schedule(function()
        if finished then return end
        finished = true
        if timer then timer:stop(); timer:close() end
        if active and not active() then
          if opts.cleanup then opts.cleanup() end
          return
        end
        result.stdout, result.stderr = table.concat(stdout), table.concat(stderr)
        result.truncated, result.timed_out = truncated, stopping == 'timeout'
        if observer_error then result.code = -1 end
        deliver(result)
      end)
    end)
  end)
  if not ok then return deliver({ code = -1, stdout = '', stderr = tostring(err) }) end
  local started = vim.uv.now()
  timer = vim.uv.new_timer()
  timer:start(opts.poll_ms or 50, opts.poll_ms or 50, vim.schedule_wrap(function()
    if finished then return end
    if active and not active() then stop('cancel')
    elseif vim.uv.now() - started >= (opts.timeout_ms or 60000) then stop('timeout') end
  end))
end

function M.format(result)
  return (result.stdout or '') .. (result.stderr or '')
    .. (result.truncated and '\n[output truncated: 20000-byte limit]' or '')
    .. '\n[exit code: ' .. tostring(result.code) .. ']'
    .. (result.timed_out and ' [timed out]' or '')
end

return M
