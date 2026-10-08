#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
data_dir=$(mktemp -d)
trap 'rm -rf "$data_dir"' EXIT
export XDG_DATA_HOME="$data_dir"

for suite in headless providers ui agent_tools approval approval_prompt trusted_workspaces trust_commands history history_picker; do
  nvim --headless -u NONE -l "tests/$suite.lua"
  printf '%s: passed\n' "$suite"
done
