#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
data_dir=$(mktemp -d)
trap 'rm -rf "$data_dir"' EXIT
export XDG_DATA_HOME="$data_dir"
export XDG_STATE_HOME="$data_dir/state"

for suite in module_layout headless stop tool_limits providers rate_limits streaming copilot_auth copilot_responses codex highlight ui managed_tab table_popup slash_commands agent_tools tool_contracts unified_tools tool_log tool_expansion user_tools process background_tasks subagents instruction_batches approval approval_queue reviewer_tools cost_review approval_format approval_prompt question_prompt assistant_pane popup_chat chat_folds chat_scroll write_approval trusted_workspaces trust_commands history history_picker compact context_edit context_review auto_compact compaction_policy model_limits settings_menu settings feature_settings model_presets skill_frontmatter skill_context skill_invocation context_files; do
  if [ "$suite" = context_files ] || [ "$suite" = skill_context ] || [ "$suite" = skill_invocation ]; then
    mkdir -p "$data_dir/home-$suite"
    HOME="$data_dir/home-$suite" nvim --headless -u NONE -l "tests/$suite.lua"
  elif [ "$suite" = ui ]; then
    # Script mode (-l) does not apply screen resizing to the window layout.
    nvim --headless -u NONE \
      -c "lua local ok, err = pcall(dofile, 'tests/ui.lua'); if not ok then io.stderr:write(tostring(err) .. '\\n'); vim.cmd('cquit 1') end" \
      -c 'qa!'
  else
    nvim --headless -u NONE -l "tests/$suite.lua"
  fi
  printf '%s: passed\n' "$suite"
done
