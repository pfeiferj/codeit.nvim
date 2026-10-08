# codeit.nvim

A small Neovim chat assistant with OpenRouter and experimental GitHub Copilot support. Requires Neovim 0.10+ and `curl` (developed with 0.12).

## Install and configure

Install this directory with your plugin manager (for example, `dir = '/path/to/codeit.nvim'` in lazy.nvim) and call:

```lua
require('codeit').setup({
  provider = 'openrouter', -- or 'copilot'
  models = {
    openrouter = 'openai/gpt-4o-mini',
    copilot = 'gpt-4o',
  },
  -- system_prompt = 'You are a helpful Neovim coding assistant.',
  -- max_tool_rounds = 12,
  -- approval = {
  --   trusted_workspaces = {
  --     ['/absolute/path/to/project'] = 'all',     -- auto-approve reads inside this workspace
  --     ['/absolute/path/to/other'] = 'tracked',   -- auto-approve only Git-tracked file reads
  --   },
  --   validators = {
  --     function(name, args, context)
  --       -- return 'approve', 'ask', or 'reject', optionally with a reason
  --       if name == 'run_command' and args.argv and args.argv[1] == 'rm' then
  --         return 'reject', 'Deletion commands are disabled'
  --       end
  --       -- context.workspace and context.user_request are available here
  --     end,
  --   },
  -- },
})
```

For OpenRouter, set `OPENROUTER_API_KEY` in the environment before starting Neovim. Requests are sent to `https://openrouter.ai/api/v1/chat/completions` using OpenAI-compatible chat completions. Choose a model with tool-calling support to use editor tools.

For Copilot, authenticate with `gh auth login` or set `GH_TOKEN` / `GITHUB_TOKEN` to a GitHub token associated with a Copilot-enabled account. The plugin exchanges this token via GitHub's Copilot token endpoint, then sends requests to the Copilot chat completions endpoint. This integration uses GitHub's internal, undocumented API and may break or require different credentials; it is not the OpenRouter API and does not use an OpenRouter key.

## Use

- `:Codeit` toggles the chat sidebar (transcript above, input below). In the input, type a message and press `<CR>` in normal mode or `<C-s>` in insert mode; `<CR>` in insert mode inserts a newline. Press `q` in normal mode in either pane to close it.
- `:CodeitSend your question` sends a message directly. `:CodeitSend` sends the text currently in the input pane.
- `:CodeitNew` clears the conversation and cancels outstanding responses or pending edits.
- `:CodeitProvider openrouter` / `:CodeitProvider copilot` switches providers and starts a fresh conversation.
- `:CodeitTrust` prompts you to trust the current workspace for **all files** or **Git-tracked files only**. `:CodeitTrust all` / `:CodeitTrust tracked` chooses directly. `:CodeitTrustStatus` shows the current mode; `:CodeitUntrust` revokes it. Choices persist across Neovim sessions.

Closing the sidebar does not discard the conversation. The source buffer for buffer tools is the file buffer active when the sidebar was opened. Agent workspace tools use Neovim's current working directory as the workspace root. Messages are kept only in memory for the current Neovim session. Requests are asynchronous but responses are not streamed.

The chat's cost/token usage line stays visible at the top of the transcript as you scroll. For OpenRouter it shows session cost in USD, cumulative input (`In`) and output (`Out`) tokens in millions (`m`) across chat and reviewer requests, and the latest main-chat response's context length (`Context`) in thousands (`k`; from `total_tokens` or input + output tokens). Displayed numbers have at most three decimal places. A `+` after a total means some requests omitted that usage field; `—` means the latest context is unavailable. Copilot does not show usage figures because its chat API does not report billed credits. `:CodeitNew`, switching providers, and `setup()` reset these figures. Closing and reopening the sidebar preserves them.

## Agent tools

The assistant can:

- List and search workspace files (`list_workspace_files`, `search_workspace`; requires `rg`), and read files or loaded buffers (`read_file`, `list_buffers`, `read_buffer`). File reads include unsaved buffer contents.
- Edit existing file buffers (`edit_file`, `replace_buffer_lines`) or create a new file (`create_file`). Existing-file edits are **not saved** automatically; review and save them in Neovim. New files are created on disk in existing directories.
- Run builds, tests, or linters via `run_command` (argument vector, no implicit shell), inspect loaded-buffer diagnostics (`get_diagnostics`), and inspect workspace Git changes (`git_status`, `git_diff`). Git diff shows unstaged tracked changes, not untracked files or unsaved buffers.
- Fetch HTTP(S) URLs using `fetch_url` (`curl` required). This is not a web search engine or an MCP integration.

Read tools require approval by default. Use `:CodeitTrust` to trust Neovim's current working directory interactively; choices are stored in `stdpath('data')/codeit/trusted_workspaces.json` (mode `0600`). You can also set `approval.trusted_workspaces` to a map of absolute workspace directories to `'all'` or `'tracked'`; choices made with the commands override configuration for that workspace, including `:CodeitUntrust`. Trust applies only when the current workspace resolves to that directory; it does not extend to parent or child workspaces. In `'all'` mode, reads of files physically inside that workspace are auto-approved, including untracked files. In `'tracked'` mode, individual file/buffer reads are auto-approved only for Git-tracked files. Workspace-wide searches and file listings, unfiltered diagnostics, and Git status still ask in `'tracked'` mode because they can expose untracked content or names; Git diff and diagnostics for a tracked file are auto-approved. Buffer listings ask if any loaded named buffer points outside the allowed files. Symlinks to files outside the trusted workspace always ask. Trust is granted explicitly; there is no implicit trust for the plugin's own directory.

Edits, creation, commands, URL fetches, and unknown tools require approval in either mode. The prompt offers **Approve once**, **Always approve exact call**, **Reject** (with an optional explanation sent back to the agent), **Cancel task**, and **Ask reviewer**. Dismissing the prompt rejects the call. The reviewer is a separate, tool-free conversation with the configured model: ask follow-up questions, then return to the original decision. Cancelling stops the task and drops its unfinished tool-call batch, leaving earlier conversation intact.

Always-approved signatures include the workspace's resolved path, tool name, and full arguments (independent of JSON object key order); their hashes are saved across Neovim sessions in `stdpath('data')/codeit/approvals.json`. Explicit per-call approvals remain effective even if workspace trust changes; delete that file to revoke saved approvals. Configure `approval.validators` in `setup()` with functions receiving `(name, args, context)` that return `'approve'`, `'ask'`, `'reject'`, or `nil`, optionally with a reason. Validators run for **every** call, including saved approvals; rejection wins over asking, and asking wins over approval or saved/default auto-approval. Errors or invalid decisions reject the call.

Buffer edits check for changes while confirmation is pending; file paths are restricted to the current workspace, including symlink targets. Commands run in that workspace but, once approved, can access the wider system. Outputs and file reads are bounded; use smaller searches or line ranges when needed. This is a local approximation of common VS Code Copilot Agent capabilities, not VS Code's exact or extension-provided tool set.

Run all headless tests from the repository root with `sh tests/run.sh`. The runner isolates saved approvals in a temporary data directory and exits with an error if a suite fails.
