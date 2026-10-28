local M = {}

local alibaba_models = {
  ['deepseek/deepseek-v3.2'] = true,
  ['qwen/qwen3-max'] = true,
  ['qwen/qwen-plus'] = true,
  ['qwen/qwen3.6-plus'] = true,
  ['qwen/qwen3-coder-plus'] = true,
  ['qwen/qwen3-coder-flash'] = true,
}

function M.breakpoints(body, copilot)
  local model = body.model:gsub(':.*$', '')
  local claude = copilot and model:match('^claude%-') or model:match('^anthropic/claude%-')
  if not claude and not (not copilot and alibaba_models[model]) then return end

  -- Keep a fixed instruction boundary and two rolling history boundaries. Using
  -- the previous boundary as well helps providers find the last round's cache.
  -- Three markers stay below Anthropic's four-breakpoint limit.
  local system, recent = nil, {}
  for index, message in ipairs(body.messages) do
    local content = message.content
    local part
    if type(content) == 'string' and content ~= '' then
      part = 1
    elseif type(content) == 'table' then
      for i, block in ipairs(content) do
        if block.type == 'text' and type(block.text) == 'string' and block.text ~= '' then part = i end
      end
    end
    if part then
      local boundary = { index = index, part = part }
      if message.role == 'system' or message.role == 'developer' then system = boundary
      else
        recent[#recent + 1] = boundary
        if #recent > 2 then table.remove(recent, 1) end
      end
    end
  end
  if system then table.insert(recent, 1, system) end
  for _, boundary in ipairs(recent) do
    -- Chat payloads shallow-copy messages; never mutate transcript content parts.
    local message = body.messages[boundary.index]
    message.content = type(message.content) == 'string'
      and { { type = 'text', text = message.content } } or vim.deepcopy(message.content)
    message.content[boundary.part].cache_control = { type = 'ephemeral' }
  end
end

return M
