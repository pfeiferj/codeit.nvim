# Agent guidance for codeit.nvim

## Project and scope

Codeit is a Lua-based Neovim chat integration with provider backends, workspace tools,
approval flows, and a dedicated chat UI. See `README.md` for user-facing behavior
and the Development section for architecture details.

- Keep changes focused on the requested behavior and preserve unrelated work.
- Follow the surrounding Lua style and existing module patterns.
- Update the README when changing user-facing commands, settings, or behavior.
- Preserve trust checks, approval boundaries, and unsaved user buffers when changing
  workspace tools or editor interactions.

## Architecture

- Source lives under `lua/codeit/`; tests are grouped by behavior under `tests/`.
- Keep `require('codeit')`, `require('codeit.ui')`, and
  `require('codeit.settings')` as the public entry points.
- Keep responsibilities in their existing areas: `chat/` for conversation lifecycle
  and requests, `ui/` for presentation, `context/` for context assembly and trusted
  sources, `settings/` for configuration, and `tools/` for agent tools and approvals.
- Controller components communicate through the explicit session/helper interface,
  not by importing the main `codeit` entry point.
- Keep mutable session and UI state per instance, not in component module globals;
  secondary chats must remain independent.
- Keep backend-specific authentication and options in provider backend modules;
  shared protocols and transport belong in `providers/protocols/` and
  `providers/http.lua`.

## Tests and data isolation

**Tests must always use separate temporary data directories. Never run tests
against the default Neovim data directory or real Codeit user data.** This applies
to full suites, individual tests, ad hoc checks, and headless reproductions.

- Set `XDG_DATA_HOME` and `XDG_STATE_HOME` to fresh temporary directories **before
  starting Neovim**. `-u NONE` alone does not isolate persisted data.
- Give each test suite its own directories so settings, approvals, trust, history,
  and other persisted state cannot leak between suites or affect the user's setup.
- Use an isolated `HOME` as well when testing home-based instruction or skill
  discovery. Isolate any additional filesystem locations exercised by a test.
- Clean up only the temporary directories created for the test. Never delete or
  modify the user's normal Neovim data to prepare or clean up tests.
- Prefer the existing runner, which handles per-suite data/state isolation:

  ```sh
  sh tests/run.sh
  ```

For a focused ordinary Lua suite, run from the repository root with isolation:

```sh
(
  test_dir=$(mktemp -d)
  trap 'rm -rf "$test_dir"' EXIT
  export XDG_DATA_HOME="$test_dir/data"
  export XDG_STATE_HOME="$test_dir/state"
  mkdir -p "$XDG_DATA_HOME" "$XDG_STATE_HOME"
  nvim --headless -u NONE -l tests/integration/public_api_and_isolation_test.lua
)
```

The runner discovers `*_test.lua` files recursively and runs them in sorted order,
each in a separate Neovim process. Add regression tests in the relevant feature
directory for behavior changes; helper files must not use that suffix. Some UI
suites require editor-mode launches rather than `nvim -l`; follow their existing
entries in `tests/run.sh` and add a special entry when needed.

Run focused checks for small changes and the relevant broader suite for larger
changes. Report the checks actually run and any verification limitations.
