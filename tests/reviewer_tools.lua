vim.opt.runtimepath:prepend(vim.fn.getcwd())
local reviewer = require('codeit.tools.reviewer')
local transcript = {
  { role = 'user', content = 'Keep my changes\nneedle' },
  { role = 'assistant', content = 'Plan', _copilot_reasoning = 'private-secret', reasoning_details = 'private-secret',
    tool_calls = { { id = 'edit', ['function'] = { name = 'edit_file', arguments = '{"path":"file.lua"}' } } } },
  { role = 'tool', tool_call_id = 'edit', content = 'Rejected by user' },
}
local tools = reviewer.new(transcript)
local function execute(name, args) return vim.json.decode(tools.execute(name, args or {})) end
local read = execute('read_chat_history')
local text = table.concat(read.lines, '\n')
assert(text:find('Keep my changes', 1, true) and text:find('Rejected by user', 1, true))
assert(text:find('edit_file', 1, true) and not text:find('private-secret', 1, true))
assert(not read.truncated and #read.lines == read.total_lines)
local search = execute('search_chat_history', { query = 'needle' })
assert(#search.matches == 1 and search.matches[1].text == 'needle')
local line = search.matches[1].line_number
assert(execute('read_chat_history', { start_line = line, end_line = line }).lines[1] == 'needle')
assert(#execute('search_chat_history', { query = 'NEEDLE' }).matches == 0)
assert(#execute('search_chat_history', { query = 'file.lua' }).matches == 1)
transcript[1].content = 'Changed after snapshot'
assert(execute('search_chat_history', { query = 'needle' }).matches[1].line_number == line)
for _, args in ipairs({ { start_line = 0 }, { start_line = 1.5 }, { end_line = '2' },
  { start_line = 3, end_line = 2 }, { unexpected = true } }) do
  assert(tools.execute('read_chat_history', args):match('^Error:'))
end
for _, args in ipairs({ {}, { query = '' }, { query = string.rep('a', 501) }, { query = false } }) do
  assert(tools.execute('search_chat_history', args):match('^Error:'))
end
assert(tools.execute('read_chat_history', vim.NIL):match('^Error:'))
assert(tools.execute('run_command', {}):match('^Error: unknown reviewer tool'))
assert(#execute('read_chat_history', { start_line = 999 }).lines == 0)

local many = {}
for i = 1, 300 do many[i] = 'match ' .. i end
local paged = reviewer.new({ { role = 'user', content = table.concat(many, '\n') } })
local page = vim.json.decode(paged.execute('read_chat_history', {}))
assert(#page.lines == 200 and page.truncated and page.next_start_line == 201)
local next_page = vim.json.decode(paged.execute('read_chat_history', { start_line = page.next_start_line }))
assert(not next_page.truncated and next_page.line_numbers[1] == 201)
page = vim.json.decode(paged.execute('search_chat_history', { query = 'match' }))
assert(#page.matches == 50 and page.truncated)
next_page = vim.json.decode(paged.execute('search_chat_history', { query = 'match', start_line = page.next_start_line }))
assert(next_page.matches[1].text == 'match 51')
local huge = reviewer.new({ { role = 'tool', content = string.rep('λ', 20000) } })
page = vim.json.decode(huge.execute('read_chat_history', {}))
assert(page.truncated and #huge.execute('read_chat_history', {}) <= 20000)
local chunks = {}
local start = 2 -- skip the message heading
repeat
  page = vim.json.decode(huge.execute('read_chat_history', { start_line = start }))
  vim.list_extend(chunks, page.lines)
  start = page.next_start_line
until not page.truncated
assert(table.concat(chunks) == string.rep('λ', 20000), 'long Unicode lines must remain readable in full')

local requests, pending, usage_count = {}, nil, 0
package.loaded['codeit.providers'] = { chat = function(config, history, specs, callback)
  requests[#requests + 1] = { config = config, history = vim.deepcopy(history), specs = specs }
  pending = callback
end }
local function call(name, args, id)
  return { id = id or name, type = 'function', ['function'] = { name = name, arguments = vim.json.encode(args) } }
end
local history = { { role = 'user', content = 'Is it safe?' } }
local result, error_result, live = nil, nil, true
local function run()
  reviewer.chat({ model = 'review' }, history, transcript, function(message, err)
    result, error_result = message, err
  end, function() return live end, function() usage_count = usage_count + 1 end)
end
run()
pending({ role = 'assistant', tool_calls = {
  call('search_chat_history', { query = 'Plan' }), call('read_chat_history', {}), call('edit_file', {}),
} })
assert(#requests == 2 and usage_count == 1)
assert(#requests[2].specs == 2 and requests[2].history[2].role == 'assistant')
assert(requests[2].history[5].content:match('^Error: unknown reviewer tool'))
pending({ role = 'assistant', content = 'Safe' })
assert(result.content == 'Safe' and usage_count == 2)
-- The approval layer adds the final answer; intermediate calls persist for follow-ups.
history[#history + 1] = result
history[#history + 1] = { role = 'user', content = 'Why?' }
run()
assert(requests[#requests].history[#history - 1].content == 'Safe')
local before = #requests
live = false
pending({ role = 'assistant', tool_calls = { call('read_chat_history', {}) } })
assert(#requests == before and usage_count == 2, 'cancelled review must not continue or record usage')
live, result, error_result = true, nil, nil
run()
pending(nil, 'offline')
assert(error_result == 'offline')
result, error_result = nil, nil
run()
pending({ role = 'assistant', tool_calls = { call('read_chat_history', {}, 'duplicate'), call('read_chat_history', {}, 'duplicate') } })
assert(error_result == 'Malformed reviewer tool call')
error_result = nil
run()
pending({ role = 'assistant', tool_calls = { call('read_chat_history', {}) } })
for _ = 1, 8 do pending({ role = 'assistant', tool_calls = { call('read_chat_history', {}) } }) end
assert(error_result == 'Reviewer tool call limit reached')
result, error_result = nil, nil
run()
local calls = {}
for i = 1, 33 do calls[i] = call('read_chat_history', {}, tostring(i)) end
pending({ role = 'assistant', tool_calls = calls })
assert(error_result == 'Reviewer tool call limit reached')
print('codeit reviewer tools tests passed')
