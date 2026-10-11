local M = {}

local function normalize_optional(value, schema)
  if type(value) ~= 'table' then return end
  if schema.type == 'object' then
    for key, property in pairs(schema.properties or {}) do
      -- Normalize before validation so approvals and execution see the same defaults.
      if value[key] == '' and not vim.tbl_contains(schema.required or {}, key) then
        value[key] = nil
      elseif value[key] ~= nil then
        normalize_optional(value[key], property)
      end
    end
  elseif schema.type == 'array' and schema.items then
    for _, item in ipairs(value) do normalize_optional(item, schema.items) end
  end
end

local function validate_value(value, property, key)
  local kind = property.type
  if kind == 'integer' then
    if type(value) ~= 'number' or value == math.huge or value % 1 ~= 0
      or value < (property.minimum or 0) or property.maximum and value > property.maximum then
      return key .. ' must be a valid integer'
    end
  elseif kind == 'array' then
    if type(value) ~= 'table' or not vim.islist(value) then return key .. ' must be an array' end
    if #value < (property.minItems or 0) or property.maxItems and #value > property.maxItems then
      return key .. ' has invalid number of items'
    end
    if property.items then
      for index, item in ipairs(value) do
        local err = validate_value(item, property.items, key .. '[' .. index .. ']')
        if err then return err end
      end
    end
  elseif kind == 'object' then
    if type(value) ~= 'table' or vim.islist(value) and #value > 0 then return key .. ' must be an object' end
    for _, required in ipairs(property.required or {}) do
      if value[required] == nil then return key .. ': missing argument ' .. required end
    end
    for field, item in pairs(value) do
      local child = property.properties[field]
      if not child then return key .. ': unknown argument ' .. tostring(field) end
      local err = validate_value(item, child, key .. '.' .. field)
      if err then return err end
    end
  elseif type(value) ~= kind then return key .. ' must be a ' .. kind end
  if property.enum and not vim.tbl_contains(property.enum, value) then return key .. ' has invalid value' end
  if kind == 'string' and (#value < (property.minLength or 0) or property.maxLength and #value > property.maxLength) then
    return key .. ' has invalid length'
  end
end

function M.validate(specs, name, args)
  if type(name) ~= 'string' or type(args) ~= 'table' or vim.islist(args) and #args > 0 then
    return 'tool name must be a string and arguments must be an object'
  end
  for _, definition in ipairs(specs) do
    local fn = definition['function']
    if fn.name == name then
      normalize_optional(args, fn.parameters)
      for _, key in ipairs(fn.parameters.required or {}) do
        if args[key] == nil then return 'missing argument ' .. key end
      end
      for key, value in pairs(args) do
        local property = fn.parameters.properties[key]
        if not property then return 'unknown argument ' .. tostring(key) end
        local err = validate_value(value, property, tostring(key))
        if err then return err end
      end
      if name == 'edit_file' or name == 'edit_loaded_buffer' or name == 'edit_source_buffer' then
        local total = 0
        for _, edit in ipairs(args.edits) do
          if (edit.start_line == nil) ~= (edit.end_line == nil) then return 'edit range requires both start_line and end_line' end
          if edit.end_line and edit.end_line < edit.start_line then return 'invalid edit range' end
          if edit.old_text == '' then return 'old_text must be nonempty' end
          total = total + #edit.old_text + #edit.new_text
        end
        if total > 200000 then return 'replacement text must total at most 200KB' end
      end
      if name == 'read_skill_resource' and args.end_line and args.end_line < (args.start_line or 1) then
        return 'invalid resource line range'
      end
      if name == 'ask_user' then
        if vim.trim(args.question) == '' or args.question:gsub('[\n\r\t]', ''):find('%c') then
          return 'question must be nonempty text without unsupported control characters'
        end
        for _, choice in ipairs(args.choices or {}) do
          if vim.trim(choice) == '' or choice:find('%c') then return 'choices must be nonempty single-line text' end
        end
      end
      return
    end
  end
  return 'unknown tool ' .. name .. '; use the advertised tools (read_loaded_buffer accepts buffer_id)'
end

return M
