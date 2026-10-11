#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
data_dir=$(mktemp -d)
trap 'rm -rf "$data_dir"' EXIT
export XDG_DATA_HOME="$data_dir"
export XDG_STATE_HOME="$data_dir/state"

find tests -type f -name '*_test.lua' > "$data_dir/suites"
LC_ALL=C sort -o "$data_dir/suites" "$data_dir/suites"

while IFS= read -r suite; do
  (
    case "$suite" in
      tests/context/context_files_test.lua|tests/skills/skill_context_test.lua|tests/skills/skill_invocation_test.lua)
        HOME="$data_dir/home/${suite%.lua}"
        mkdir -p "$HOME"
        export HOME
        ;;
    esac

    case "$suite" in
      tests/ui/layout_and_interaction_test.lua|tests/ui/chat_folds_insert_test.lua)
        # Layout resizing and actual Insert mode require editor mode, not -l.
        CODEIT_TEST_FILE="$suite" nvim --headless -u NONE \
          -c "lua local ok, err = pcall(dofile, vim.env.CODEIT_TEST_FILE); if not ok then io.stderr:write(tostring(err) .. '\\n'); vim.cmd('cquit 1') end" \
          -c 'qa!'
        ;;
      *)
        nvim --headless -u NONE -l "$suite"
        ;;
    esac
  )
  printf '%s: passed\n' "$suite"
done < "$data_dir/suites"
