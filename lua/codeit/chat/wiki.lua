local M = {}
local wiki = require('codeit.wiki')
local providers = require('codeit.providers')
local history = require('codeit.chat.storage')

function M.attach(_, session, helpers)
  local queue, running = {}, false
  local function warn(err)
    vim.notify('codeit: could not update personal wiki: ' .. tostring(err), vim.log.levels.WARN)
  end
  local run_next
  run_next = function()
    if running or #queue == 0 then return end
    running = true
    local job = table.remove(queue, 1)
    local function finish(err)
      if err then warn(err) end
      running = false
      vim.schedule(run_next)
    end
    if not job.active() then return finish() end
    local ok, store, err = pcall(wiki.open, job.root)
    if not ok then return finish(store) end
    if not store then return finish(err) end
    local catalog
    ok, catalog, err = pcall(wiki.catalog, store)
    if not ok then return finish(catalog) end
    if not catalog then return finish(err) end
    local function request(prompt, input, callback)
      if not job.active() then return finish() end
      local called = false
      local success, failure = pcall(providers.chat, job.config, {
        { role = 'system', content = prompt },
        { role = 'user', content = vim.json.encode(input) },
      }, {}, function(message, request_err, usage)
        if called then return end
        called = true
        job.bill(usage, request_err)
        if not job.active() then return finish() end
        if request_err then return finish(request_err) end
        local result, parse_err = wiki.decode(message)
        if not result then return finish(parse_err) end
        callback(result)
      end)
      if not success and not called then finish(failure) end
    end
    request(wiki.plan_prompt, { turn = job.turn, workspace = job.workspace, catalog = catalog }, function(plan)
      if type(plan.notes) ~= 'string' or #plan.notes > 16384 then return finish('invalid wiki notes') end
      local pages, select_err = wiki.select(store, plan.paths)
      if not pages then return finish(select_err) end
      if vim.trim(plan.notes) == '' then return finish() end
      request(wiki.update_prompt, { notes = plan.notes, workspace = job.workspace, catalog = catalog, pages = pages }, function(result)
        local applied, apply_err
        ok, applied, apply_err = pcall(wiki.apply, store, result.pages)
        if not ok then return finish(applied) end
        finish(not applied and apply_err or nil)
      end)
    end)
  end

  function helpers.review_wiki_turn(billed_turn)
    local options = session.config.personal_wiki
    if not options or not options.enabled then return end
    billed_turn = billed_turn or session.turn_costs[#session.turn_costs]
    local first, last = billed_turn and billed_turn.first, #session.messages
    if not first then return end
    local turn = helpers.redact_disabled_skill_results(vim.deepcopy(vim.list_slice(session.messages, first, last)))
    for _, message in ipairs(turn) do
      message._copilot_reasoning, message._codex_reasoning, message.reasoning_details = nil, nil, nil
    end
    if #vim.json.encode(turn) > 131072 then return warn('turn exceeds wiki review limits') end
    if #queue >= 16 then return warn('wiki review queue is full') end
    local generation, revision = session.generation, session.wiki_revision
    local workspace, chat = session.workspace, session.chat_id
    local selected = helpers.request_config('personal_wiki')
    local root = options.root
    queue[#queue + 1] = {
      root = root, turn = turn, workspace = workspace, config = selected,
      active = function()
        return session.generation == generation and session.wiki_revision == revision
          and session.workspace == workspace and history.workspace() == workspace and session.chat_id == chat
          and session.config.personal_wiki.enabled and session.config.personal_wiki.root == root
      end,
      bill = function(usage, err)
        if session.workspace ~= workspace or session.chat_id ~= chat or session.generation ~= generation then return end
        if not err then
          helpers.record_usage(usage, 'personal_wiki', selected.provider, billed_turn)
        end
      end,
    }
    vim.schedule(run_next)
  end
end

return M
