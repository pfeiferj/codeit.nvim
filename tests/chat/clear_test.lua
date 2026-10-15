vim.opt.runtimepath:prepend(vim.fn.getcwd())
local temp = vim.fn.tempname()
vim.fn.mkdir(temp, 'p')
vim.fn.chdir(temp)
local requests, pending = {}, {}
package.loaded['codeit.providers'] = { chat = function(_, messages, _, callback, on_text, active)
  requests[#requests + 1] = vim.deepcopy(messages)
  pending[#pending + 1] = { reply = callback, text = on_text, active = active }
end }
local codeit = require('codeit')
local history = require('codeit.chat.storage')
local workspace = history.workspace()
codeit.setup({ max_context_tokens = false, context_review = false })
assert(vim.fn.exists(':CodeitClear') == 2)
codeit.clear()
assert(#requests == 0 and #history.list(workspace) == 0, 'clearing an empty chat must not request or create a chat')
codeit.send('old question')
pending[1].reply({ role = 'assistant', content = 'old answer' }, nil,
  { cost = 0.25, prompt_tokens = 100, completion_tokens = 20 })
local saved = history.list(workspace)[1]
local id = saved.id
saved.messages[1].content = 'Custom system prompt'
saved.context_summary, saved.compacted_until, saved.context_summary_skills = 'Old summary', 3, {}
saved.summary = 'Old history title'
saved.context_paths = { temp .. '/attached.txt' }
saved.selected_skills = { { name = 'old-skill', path = temp .. '/SKILL.md' } }
saved.disabled_context_files = { [temp .. '/disabled.md'] = true }
saved.context_reviews = { { first = 2, last = 3, summary = 'Old review' } }
saved.command_results = { { command = '/old', output = 'Old output', after_message = 3 } }
assert(history.save(workspace, id, saved))
assert(codeit.resume(id))
codeit.open()
local buf = vim.fn.bufnr('codeit://chat')
local function clear_draft()
  local row = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_buf_set_lines(buf, row - 1, -1, false, { '/clear' })
  codeit.send()
end
clear_draft()
assert(#requests == 1, '/clear must not invoke a model')
local cleared = history.load(workspace, id)
assert(cleared and #history.list(workspace) == 1, 'clear must keep the same session')
assert(#cleared.messages == 1 and cleared.messages[1].content == 'Custom system prompt')
assert(not cleared.context_summary and not cleared.compacted_until and not cleared.context_summary_skills)
assert(not cleared.summary, 'clear must remove the cached history summary')
assert(#cleared.context_paths == 0 and #cleared.selected_skills == 0 and #cleared.context_reviews == 0)
assert(cleared.disabled_context_files[temp .. '/disabled.md'], 'keep context-file preferences')
assert(cleared.cost == saved.cost and cleared.tokens_in == saved.tokens_in and cleared.tokens_out == saved.tokens_out)
assert(#cleared.turn_costs == 0, 'deleted messages must not leave stale per-turn indices')
assert(#cleared.command_results == 1 and cleared.command_results[1].command == '/clear')
local transcript = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
assert(not transcript:find('old question', 1, true) and not transcript:find('Old output', 1, true))
assert(transcript:find('Context cleared', 1, true))
assert(codeit.resume(id))
codeit.send('fresh question')
assert(#requests[2] == 2 and requests[2][1].content == 'Custom system prompt'
  and requests[2][2].content == 'fresh question', 'deleted context must not return after resume')
local stale = pending[2]
stale.text('Partial response to delete')
clear_draft()
assert(not stale.active(), 'clear must invalidate the active response')
stale.text('Stale preview')
stale.reply({ role = 'assistant', content = 'Stale answer' })
assert(#history.load(workspace, id).messages == 1, 'late responses must not restore deleted context')
codeit.send('after interruption')
assert(#requests[3] == 2 and requests[3][2].content == 'after interruption')
pending[3].reply({ role = 'assistant', content = 'fresh answer' })
codeit.compact(true)
local stale_summary = pending[4]
vim.cmd('CodeitClear')
stale_summary.reply({ role = 'assistant', content = 'Stale compacted summary' })
cleared = history.load(workspace, id)
assert(#cleared.messages == 1 and not cleared.context_summary, 'late compaction must not restore context')
codeit.new()
codeit.send('other conversation')
pending[5].reply({ role = 'assistant', content = 'other answer' })
local other_id = history.list(workspace)[1].id
assert(other_id ~= id)
assert(codeit.resume(id))
codeit.clear()
assert(#history.load(workspace, other_id).messages == 3, 'clear must not affect other sessions')
vim.fn.delete(temp, 'rf')
print('codeit clear tests passed')
