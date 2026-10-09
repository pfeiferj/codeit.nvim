#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
data_dir=$(mktemp -d)
trap 'rm -rf "$data_dir"' EXIT
export XDG_DATA_HOME="$data_dir"

for suite in headless providers ui slash_commands agent_tools approval approval_format approval_prompt write_approval trusted_workspaces trust_commands history history_picker compact context_edit auto_compact model_limits context_files; do
  if [ "$suite" = context_files ]; then
    mkdir -p "$data_dir/home"
    HOME="$data_dir/home" nvim --headless -u NONE -l "tests/$suite.lua"
  else
    nvim --headless -u NONE -l "tests/$suite.lua"
  fi
  printf '%s: passed\n' "$suite"
done
