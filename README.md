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

Closing the sidebar does not discard the conversation. The source buffer for buffer tools is the file buffer active when the sidebar was opened. Agent workspace tools use Neovim's current working directory as the workspace root. Messages are kept only in memory for the current Neovim session. Requests are asynchronous but responses are not streamed.

## Agent tools

The assistant can:

- List and search workspace files (`list_workspace_files`, `search_workspace`; requires `rg`), and read files or loaded buffers (`read_file`, `list_buffers`, `read_buffer`). File reads include unsaved buffer contents.
- Edit existing file buffers (`edit_file`, `replace_buffer_lines`) or create a new file (`create_file`). Existing-file edits are **not saved** automatically; review and save them in Neovim. New files are created on disk in existing directories.
- Run builds, tests, or linters via `run_command` (argument vector, no implicit shell), inspect loaded-buffer diagnostics (`get_diagnostics`), and inspect workspace Git changes (`git_status`, `git_diff`). Git diff shows unstaged tracked changes, not untracked files or unsaved buffers.
- Fetch HTTP(S) URLs using `fetch_url` (`curl` required). This is not a web search engine or an MCP integration.

Read-only tools are auto-approved by default; edits, creation, commands, URL fetches, and unknown tools require approval. The prompt offers **Approve once**, **Always approve exact call**, **Reject** (with an optional explanation sent back to the agent), **Cancel task**, and **Ask reviewer**. Dismissing the prompt rejects the call. The reviewer is a separate, tool-free conversation with the configured model: ask follow-up questions, then return to the original decision. Cancelling stops the task and drops its unfinished tool-call batch, leaving earlier conversation intact.

Always-approved signatures include the workspace's resolved path, tool name, and full arguments (independent of JSON object key order); their hashes are saved across Neovim sessions in `stdpath('data')/codeit/approvals.json`. Delete that file to revoke saved approvals. Configure `approval.validators` in `setup()` with functions receiving `(name, args, context)` that return `'approve'`, `'ask'`, `'reject'`, or `nil`, optionally with a reason. Validators run for **every** call, including saved approvals; rejection wins over asking, and asking wins over approval or saved/default auto-approval. Errors or invalid decisions reject the call.

Buffer edits check for changes while confirmation is pending; file paths are restricted to the current workspace, including symlink targets. Commands run in that workspace but, once approved, can access the wider system. Outputs and file reads are bounded; use smaller searches or line ranges when needed. This is a local approximation of common VS Code Copilot Agent capabilities, not VS Code's exact or extension-provided tool set.

Run all headless tests from the repository root with `sh tests/run.sh`. The runner isolates saved approvals in a temporary data directory and exits with an error if a suite fails.
