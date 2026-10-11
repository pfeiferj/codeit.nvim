local M = {}
local ui = require('codeit.ui')
local approval = require('codeit.tools.approval')
local history = require('codeit.chat.storage')
local slash_commands = require('codeit.commands.slash')
local context_files = require('codeit.context.files')

function M.attach(api, session, helpers)
  local M = api
  function M.invoke_skill(name, arguments)
    helpers.sync_workspace()
    if session.busy then return false, 'wait for the current response before invoking a skill' end
    local skill = context_files.skill(name, session.workspace, approval.workspace_trust(session.workspace), true)
    if not skill then return false, 'skill is unavailable, disabled, or workspace is not trusted' end
    local rendered, err = require('codeit.skills.invocation').render(require('codeit.skills.frontmatter').body(skill.content), arguments)
    if not rendered then return false, err end
    for index = #session.selected_skills, 1, -1 do
      if session.selected_skills[index].name == name then table.remove(session.selected_skills, index) end
    end
    session.selected_skills[#session.selected_skills + 1] = { name = name, path = skill.path, arguments = arguments or '' }
    M.send('Use skill ' .. name .. ' for this task.' .. ((arguments and arguments ~= '') and ('\n\n' .. arguments) or ''))
    return true
  end

  function M.send(text)
    helpers.sync_workspace()
    local from_draft = text == nil
    text = text or ui.peek_input()
    if not text or vim.trim(text) == '' then return end
    if from_draft then
      local command, args = slash_commands.parse(text)
      if command == false then
        ui.slash_error(args)
        return
      elseif command then
        local err = slash_commands.validate(command, args)
        if err then
          ui.slash_error(err)
          return
        end
        if command.name == 'help' then
          ui.slash_help()
          return
        end
        if command.name == 'skill' then
          local name, arguments = require('codeit.skills.invocation').parse(args)
          if not name then ui.slash_error(arguments); return end
          local ok, err = M.invoke_skill(name, arguments)
          if not ok then ui.slash_error(err); return end
          ui.take_input()
          return
        end
        ui.take_input()
        local previous_status = session.status
        local notices = {}
        local notify = vim.notify
        vim.notify = function(message, level, opts)
          notices[#notices + 1] = tostring(message)
          return notify(message, level, opts)
        end
        local ok, result = pcall(vim.api.nvim_cmd,
          { cmd = command.command, args = args ~= '' and { args } or {} }, { output = true })
        vim.notify = notify
        if not ok then
          vim.notify('codeit: ' .. tostring(result), vim.log.levels.ERROR)
          return
        end
        local output = vim.trim(table.concat(notices, '\n'))
        if result.output and vim.trim(result.output) ~= '' then
          local ex_output = vim.trim(result.output)
          if output == '' then output = ex_output
          elseif not output:find(ex_output, 1, true) then output = output .. '\n' .. ex_output end
        end
        if output == '' then
          output = session.status ~= previous_status and session.status or 'Ran :' .. command.command
        end
        session.command_results[#session.command_results + 1] = {
          command = text, output = output, after_message = #session.messages,
        }
        helpers.save()
        helpers.render()
        return
      end
    end
    if session.busy then
      vim.notify('codeit: wait for the current response', vim.log.levels.WARN)
      return
    end
    if from_draft then
      ui.take_input()
      text = slash_commands.literal(text)
    end
    if #session.messages == 0 then
      table.insert(session.messages, { role = 'system', content = helpers.current_prompt() })
    end
    table.insert(session.messages, { role = 'user', content = text })
    session.current_turn = { first = #session.messages, cost = 0, missing_cost = 0, cost_by_function = {} }
    session.turn_costs[#session.turn_costs + 1] = session.current_turn
    if not session.chat_id then session.chat_id = history.new_id() end
    helpers.save(true)
    session.turn_reviews = vim.deepcopy(session.context_reviews)
    session.busy = true
    helpers.request(0, session.generation)
  end
end

return M
