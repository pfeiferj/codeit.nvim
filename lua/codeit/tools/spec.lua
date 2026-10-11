return function(name, description, properties, required)
  return { type = 'function', ['function'] = { name = name, description = description,
    parameters = { type = 'object', properties = properties or vim.empty_dict(),
      required = required or {}, additionalProperties = false } } }
end
