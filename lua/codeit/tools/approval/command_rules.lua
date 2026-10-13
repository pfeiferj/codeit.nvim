local M = {}

local function invalid(message)
  error('codeit: approval.read_commands ' .. message)
end

local function keys(value, allowed)
  for key in pairs(value) do
    if not allowed[key] then invalid('has unknown field ' .. tostring(key)) end
  end
end

local function integer(value, min, max)
  return type(value) == 'number' and value >= min and value <= max and value % 1 == 0
end

local function atom(value)
  if type(value) == 'string' then
    if #value > 4096 or value:find('\0', 1, true) then invalid('has an invalid literal') end
    return function(arg) return arg == value end
  end
  if type(value) ~= 'table' then invalid('matchers must be strings or tables') end
  keys(value, { string = true, file = true, integer = true, one_of = true })
  local count = 0
  for _ in pairs(value) do count = count + 1 end
  if count ~= 1 then invalid('each matcher must have exactly one type') end
  if value.file then
    if value.file ~= 'read' then invalid("file matchers must use 'read'") end
    return function(arg) return arg ~= '' and arg ~= '-' end, true
  end
  if value.string then
    if value.string == true then return function() return true end end
    if type(value.string) ~= 'table' then invalid('string must be true or a pattern table') end
    keys(value.string, { pattern = true })
    local pattern = value.string.pattern
    if type(pattern) ~= 'string' then invalid('string.pattern must be a Lua pattern') end
    if #(pattern:match('(%%+)$') or '') % 2 == 1 or not pcall(string.find, '', pattern) then
      invalid('has an invalid Lua pattern')
    end
    -- Anchor the pattern: substring matches must not grant command approval.
    if pattern:sub(1, 1) ~= '^' then pattern = '^' .. pattern end
    local source_pattern = pattern
    local escapes = #(pattern:match('(%%*)%$$') or '')
    if pattern:sub(-1) ~= '$' or escapes % 2 == 1 then pattern = pattern .. '$' end
    if not pcall(string.find, '', pattern) then invalid('has an invalid Lua pattern') end
    return function(arg)
      -- Appending an anchor can accidentally complete a malformed %b token.
      -- Check the original pattern too; Lua parses patterns lazily.
      local valid, found = pcall(string.find, arg, source_pattern)
      if not valid or not found then return false end
      local ok, start = pcall(string.find, arg, pattern)
      return ok and start ~= nil
    end
  end
  if value.integer then
    local bounds = value.integer
    if type(bounds) ~= 'table' then invalid('integer must have min and max bounds') end
    keys(bounds, { min = true, max = true })
    if not integer(bounds.min, -9007199254740991, 9007199254740991)
      or not integer(bounds.max, bounds.min, 9007199254740991) then
      invalid('integer must have finite integer min <= max bounds')
    end
    local min, max = bounds.min, bounds.max
    return function(arg)
      return arg:match('^[+-]?%d+$') ~= nil and integer(tonumber(arg), min, max)
    end
  end
  if value.one_of then
    if type(value.one_of) ~= 'table' or not vim.islist(value.one_of) or #value.one_of == 0 then
      invalid('one_of must be a nonempty list of strings')
    end
    local choices = {}
    for _, choice in ipairs(value.one_of) do
      if type(choice) ~= 'string' then invalid('one_of must contain only strings') end
      atom(choice)
      choices[choice] = true
    end
    return function(arg) return choices[arg] == true end
  end
  invalid('has an invalid matcher')
end

function M.compile(rules)
  if type(rules) ~= 'table' or not vim.islist(rules) then invalid('must be a list') end
  local compiled = {}
  for _, rule in ipairs(rules) do
    if type(rule) ~= 'table' then invalid('rules must be tables with argv') end
    keys(rule, { argv = true })
    if type(rule.argv) ~= 'table' or not vim.islist(rule.argv) or #rule.argv == 0 or #rule.argv > 40
      or type(rule.argv[1]) ~= 'string' or rule.argv[1] == '' then
      invalid('argv must have 1-40 matchers starting with an exact executable')
    end
    local entries = {}
    for _, value in ipairs(rule.argv) do
      local min, max = 1, 1
      if type(value) == 'table' and value.optional ~= nil then
        keys(value, { optional = true })
        value, min, max = value.optional, 0, 1
      elseif type(value) == 'table' and value.repeat_arg ~= nil then
        keys(value, { repeat_arg = true, min = true, max = true })
        min, max = value.min, value.max
        if not integer(min, 0, 40) or not integer(max, min, 40) then
          invalid('repeat_arg requires integer bounds 0 <= min <= max <= 40')
        end
        value = value.repeat_arg
      end
      local matches, file = atom(value)
      entries[#entries + 1] = { matches = matches, file = file, min = min, max = max }
    end
    entries.definition = vim.deepcopy(rule)
    compiled[#compiled + 1] = entries
  end
  return compiled
end

local function match(entries, argv)
  local failed = {}
  local function walk(index, position)
    if index > #entries then return position == #argv + 1 and {} or nil end
    local key = index .. ':' .. position
    if failed[key] then return nil end
    local entry = entries[index]
    local count = 0
    while count < entry.max and position + count <= #argv and entry.matches(argv[position + count]) do
      count = count + 1
    end
    -- Backtrack over bounded repetitions so later required operands still match.
    for length = count, entry.min, -1 do
      local files = walk(index + 1, position + length)
      if files then
        if entry.file then
          for offset = length - 1, 0, -1 do table.insert(files, 1, argv[position + offset]) end
        end
        return files
      end
    end
    failed[key] = true
  end
  return walk(1, 1)
end

function M.match(rules, argv)
  if type(argv) ~= 'table' or not vim.islist(argv) or #argv == 0 or #argv > 40 then return {} end
  for index, arg in ipairs(argv) do
    if type(arg) ~= 'string' or #arg > 4096 or arg:find('\0', 1, true) or index == 1 and arg == '' then
      return {}
    end
  end
  local matches, definitions = {}, {}
  for _, entries in ipairs(rules) do
    local files = match(entries, argv)
    if files then
      matches[#matches + 1] = files
      definitions[#definitions + 1] = entries.definition
    end
  end
  return matches, definitions
end

return M
