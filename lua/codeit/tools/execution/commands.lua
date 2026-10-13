local M = {}
local spec = require('codeit.tools.spec')
local paths = require('codeit.tools.workspace.paths')
local runner = require('codeit.process')

M.specs = {
  spec('run_command', 'Run a command against workspace DISK files after approval (configured read-only argv rules can auto-approve after a safety assessment); unsaved edits are not included. No implicit shell. argv has 1-40 strings, each at most 4096 bytes; empty arguments allowed. Output limited to 20000 bytes, timeout 60 seconds. Cancellation terminates the process group on Unix.', {
    argv = { type = 'array', items = { type = 'string' }, description = 'Executable and arguments' },
  }, { 'argv' }),
  spec('start_background_task', 'Start an asynchronous command against workspace DISK files after approval; returns a task ID immediately so chat can continue. No implicit shell; argv follows run_command limits. View live logs and cancel in :CodeitTasks. Logs retain at most 20000 bytes. No timeout by default. Set notify_on_completion=true to request results be sent to the originating chat once idle, only after separate user approval. Tasks last for this Neovim session.', {
    argv = { type = 'array', minItems = 1, maxItems = 40, items = { type = 'string', maxLength = 4096 } },
    title = { type = 'string', minLength = 1, maxLength = 200 },
    notify_on_completion = { type = 'boolean', description = 'Request a user-approved assistant follow-up when finished (default false)' },
    timeout_ms = { type = 'integer', minimum = 1, maximum = 2147483647, description = 'Optional time limit in milliseconds; omitted means no timeout' },
  }, { 'argv', 'title' }),
}

local function process(argv, cwd, done, active)
  return runner.run(argv, cwd, function(result) done(runner.format(result)) end, active)
end

function M.execute(name, args, done, active, approve, reads, prepare, source, origin)
  local base = paths.root()
  if not base then return done('Error: workspace does not exist') end
  if name == 'run_command' or name == 'start_background_task' then
    if type(args.argv) ~= 'table' or not vim.islist(args.argv) or #args.argv == 0 or #args.argv > 40 then
      return done('Error: argv must be an array of 1-40 strings')
    end
    for index, arg in ipairs(args.argv) do
      if type(arg) ~= 'string' or index == 1 and arg == '' or #arg > 4096 or arg:find('\0', 1, true) then
        return done('Error: invalid argv string (executable must be nonempty, each argument at most 4096 bytes, no NUL)')
      end
    end
    return approve('Run in ' .. base .. ': ' .. table.concat(args.argv, ' ') .. '?',
      function()
        if name == 'run_command' then return process(args.argv, base, done, active) end
        local task = require('codeit.tools.execution.tasks').start(args, base, origin)
        done(vim.json.encode({ task_id = task.id, status = task.status,
          notify_on_completion = task.notify_on_completion }))
      end)
  end
  done('Error: unknown tool ' .. tostring(name))
end

return M
