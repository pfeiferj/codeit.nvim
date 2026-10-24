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
    local function finish(err, status, reason)
      job.review.status = not job.active() and 'cancelled' or (err and 'failed' or status or 'skipped')
      job.review.reason = err and tostring(err):sub(1, 16384) or reason
      if job.review.status == 'cancelled' then job.review.reason = 'Chat, workspace, or wiki settings changed.' end
      job.publish()
      if err then warn(err) end
      running = false
      vim.schedule(run_next)
    end
    if not job.active() then return finish() end
    job.review.status = 'reviewing'
    job.publish()
    local ok, store, err = pcall(wiki.open, job.root)
    if not ok then return finish(store) end
    if not store then return finish(err) end
    local indexed
    ok, indexed, err = pcall(wiki.catalog, store)
    if not ok then return finish(indexed) end
    if not indexed then return finish(err) end
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
    local function review(search)
      if type(search.notes) ~= 'string' or #search.notes > 16384 then return finish('invalid wiki notes') end
      job.review.notes = search.notes
      job.publish()
      if vim.trim(search.notes) == '' then return finish(nil, 'skipped', 'Nothing worth retaining.') end
      local matches, search_err = wiki.search(store, search.queries)
      if not matches then return finish(search_err) end
      request(wiki.plan_prompt, { notes = search.notes, workspace = job.workspace, matches = matches }, function(plan)
        if type(plan.notes) ~= 'string' or #plan.notes > 16384 then return finish('invalid wiki notes') end
        local allowed = {}
        for _, match in ipairs(matches) do allowed[match.path] = true end
        if type(plan.paths) == 'table' then
          for _, path in ipairs(plan.paths) do
            if not allowed[path] then return finish('wiki page was not in search results') end
          end
        end
        local pages, select_err = wiki.select(store, plan.paths)
        if not pages then return finish(select_err) end
        job.review.notes, job.review.selected = plan.notes, vim.deepcopy(plan.paths)
        job.publish()
        if vim.trim(plan.notes) == '' then return finish(nil, 'skipped', 'Nothing worth retaining.') end
        request(wiki.update_prompt, { notes = plan.notes, workspace = job.workspace, matches = matches, pages = pages }, function(result)
          local applied, apply_err
          ok, applied, apply_err = pcall(wiki.apply, store, result.pages)
          if not ok then return finish(applied) end
          if not applied then return finish((apply_err or 'wiki update failed') .. ' (A failed batch may have partially written pages.)') end
          job.review.updated = {}
          for _, page in ipairs(result.pages) do table.insert(job.review.updated, page.path) end
          finish(nil, #result.pages > 0 and 'updated' or 'skipped', #result.pages == 0 and 'No page changes needed.' or nil)
        end)
      end)
    end
    local function refresh_summaries()
      if not job.active() then return finish() end
      local batch = wiki.summary_batch(store)
      if #batch == 0 then
        return request(wiki.search_prompt, { turn = job.turn, workspace = job.workspace }, review)
      end
      request(wiki.summary_prompt, { pages = batch }, function(result)
        local applied, apply_err
        ok, applied, apply_err = pcall(wiki.apply_summaries, store, result.pages, batch)
        if not ok then return finish(applied) end
        if not applied then return finish(apply_err) end
        refresh_summaries()
      end)
    end
    refresh_summaries()
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
    local review = { status = 'queued', selected = {}, updated = {} }
    billed_turn.wiki_review = review
    local workspace, chat = session.workspace, session.chat_id
    local function publish()
      if session.workspace ~= workspace or session.chat_id ~= chat or history.workspace() ~= workspace then return end
      helpers.save()
      helpers.render()
    end
    local function skip(reason)
      review.status, review.reason = 'skipped', reason
      publish()
      warn(reason)
    end
    if #vim.json.encode(turn) > 1310720 then return skip('turn exceeds wiki review limits') end
    if #queue >= 16 then return skip('wiki review queue is full') end
    local generation, revision = session.generation, session.wiki_revision
    local selected = helpers.request_config('personal_wiki')
    local root = options.root
    queue[#queue + 1] = {
      root = root, turn = turn, workspace = workspace, config = selected,
      review = review, publish = publish,
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
    publish()
    vim.schedule(run_next)
  end
end

return M
