local next_instance = 0
local editors = require('codeit.ui.editors')

--- Create an independent chat with optional presentation overrides.
local function new(options)
  options = options or {}
  next_instance = next_instance + 1
  local M = {}
  local state = {
    chat_lines = {}, draft_start = 2, section_folds = {}, role_marks = {},
    can_send_message = true,
    ui_ns = vim.api.nvim_create_namespace('codeit_chat_ui'),
    palette_ns = vim.api.nvim_create_namespace('codeit_slash_' .. next_instance),
    slash_group = vim.api.nvim_create_augroup('codeit_chat_' .. next_instance, { clear = true }),
  }
  -- Components share this instance's data and helpers, never another chat's state.
  local helpers = {}
  require('codeit.ui.highlight').setup_roles()
  for _, component in ipairs({ 'completion', 'draft', 'folds', 'windows', 'transcript', 'chat_render' }) do
    require('codeit.ui.' .. component).attach(M, state, options, helpers)
  end
  M.show_context = editors.show_context
  M.show_context_full = editors.show_context_full
  M.show_system_prompt = editors.show_system_prompt
  function M.destroy()
    M.close()
    vim.api.nvim_del_augroup_by_id(state.slash_group)
  end
  return M
end

local M = new()
M.new = new
return M
