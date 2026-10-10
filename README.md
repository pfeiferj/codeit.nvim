# codeit.nvim

A Neovim chat assistant with OpenRouter and experimental GitHub Copilot support.
Chat in a Markdown sidebar, let the assistant inspect and edit your workspace with
approval, and resume conversations from local history.

## Contents

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Provider setup](#provider-setup)
- [Per-feature models and presets](#per-feature-models-and-presets)
- [Usage](#usage)
- [Settings](#settings)
- [Storage, usage, and logs](#storage-usage-and-logs)
- [Project instructions and skills](#project-instructions-and-skills)
- [Agent tools](#agent-tools)
- [Trust and approvals](#trust-and-approvals)
- [Development](#development)
- [License](#license)

## Requirements

- Neovim 0.10+ (developed with 0.12).
- `curl` for provider requests and URL fetches.
- `rg` (ripgrep) for workspace file listings and searches.
- Credentials for OpenRouter or a Copilot-enabled GitHub account.

## Quick start

1. Install this directory with your plugin manager. For example, with lazy.nvim:

   ```lua
   {
     dir = '/path/to/codeit.nvim',
     config = function()
       require('codeit').setup({
         provider = 'openrouter',
         models = { openrouter = 'openai/gpt-4o-mini' },
       })
     end,
   }
   ```

2. Set `OPENROUTER_API_KEY` before starting Neovim, or configure
   [Copilot authentication](#github-copilot-experimental).
3. Open `:Codeit`, type below `## Message`, and send with `<CR>` in normal mode
   or `<C-s>` in insert mode.
4. Review tool approvals as they appear. Optionally use `:CodeitTrust` to
   auto-approve workspace reads; edits and commands still require approval.

Closing the sidebar keeps the conversation. Use `:CodeitNew` for a fresh chat or
`:CodeitHistory` to resume an earlier one.

<details>
<summary>Optional setup settings</summary>

Call `require('codeit').setup()` with the options you need. You can also manage
provider, model, preset, and request settings through `:CodeitSettings`.

```lua
require('codeit').setup({
  provider = 'openrouter', -- or 'copilot'
  models = {
    openrouter = 'openai/gpt-4o-mini',
    copilot = 'gpt-4o',
  },
  -- model_presets = {
  --   fast = { model = 'openai/gpt-4o-mini', options = { effort = 'low' } },
  --   long_context = { provider = 'copilot', model = 'gpt-4o' },
  --   reasoning = { model = 'openai/gpt-4o', options = { effort = 'high' } },
  -- }, -- unset fields inherit main chat settings
  -- feature_settings = {
  --   tool_review = { preset = 'reasoning' }, -- also the default for this feature
  --   compaction = { preset = 'long_context', options = { api_host = '' } },
  --   history_summary = { model = 'openai/gpt-4o-mini' }, -- optional per-feature override
  -- }, -- see "Per-feature models and presets" below
  -- request_options = {
  --   openrouter = { preferred_provider = 'anthropic', service_tier = 'priority', effort = 'high' },
  --   copilot = { api_host = 'api.business.githubcopilot.com' }, -- default: api.githubcopilot.com
  -- },
  -- system_prompt = 'You are a helpful Neovim coding assistant.',
  -- max_tool_rounds = 12, -- tool-call batches per user turn; prompts before exceeding this
  -- context_review = false, -- disable background pruning after each completed turn (default: true)
  -- max_context_tokens = 128000, -- optional manual override; false disables auto-compaction
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

</details>

## Provider setup

### OpenRouter

For OpenRouter, set `OPENROUTER_API_KEY` in the environment before starting Neovim. Requests are sent to `https://openrouter.ai/api/v1/chat/completions` using OpenAI-compatible chat completions. Choose a model with tool-calling support to use editor tools.

### GitHub Copilot (experimental)

For Copilot, sign in using `:Copilot setup` in copilot.vim or `:Copilot auth` in copilot.lua with a Copilot-enabled GitHub account. The plugin reuses their OAuth credentials from `github-copilot/apps.json` or `hosts.json` under `$XDG_CONFIG_HOME` (default `~/.config`, or `%LOCALAPPDATA%` on Windows). Explicit environment credentials take precedence: `COPILOT_GITHUB_TOKEN`, then `GH_TOKEN`, then `GITHUB_TOKEN` (empty values are skipped). If none are available, it falls back to `gh auth token --hostname github.com`. **A GitHub CLI login or personal access token is not necessarily accepted by the Copilot token endpoint**, even for an account with Copilot access; if the exchange returns HTTP 401/403, use a Copilot OAuth login instead.

The plugin exchanges the OAuth credential for a short-lived Copilot token, then routes requests using the model catalog's `supported_endpoints`: `/chat/completions` when available, or `/responses` for Responses-only models. Endpoint metadata is cached per Copilot API host for the session and refreshed when searching models. If metadata omits endpoints (or the manually entered ID is absent), the plugin retains the legacy chat-completions path; models advertising only unsupported endpoints return an error asking you to choose another model. Responses requests replay the transcript, tool calls/results, and encrypted reasoning without server-side conversation storage. Credentials are not printed or logged by the exchange handler.

**Compatibility warning:** This integration uses GitHub's internal, undocumented API and may break or require different credentials; it is not the OpenRouter API and does not use an OpenRouter key.

### Copilot business API host

To use Copilot behind a business network policy, set `request_options.copilot.api_host = 'api.business.githubcopilot.com'` in `setup()`, or choose **Copilot API host** in `:CodeitSettings` after selecting Copilot. The setting can be applied for the session or saved globally/per workspace, and is stored with chats. It routes Copilot chat requests, model searches, and context-limit metadata to the business host unless a feature overrides `options.api_host`; there is no fallback to the standard host. Unset or blank uses `api.githubcopilot.com`. Only these two hostnames are accepted, without a URL scheme or path. Authentication still exchanges credentials at `https://api.github.com/copilot_internal/v2/token`, so that endpoint must remain reachable. Saved settings override `setup()` options as described below.

## Per-feature models and presets

Three shared presets are available: **fast** (`fast`), **long context** (`long_context`), and **reasoning** (`reasoning`). Configure them in `model_presets`, with optional `provider` (`openrouter` or `copilot`), `model`, and `options` fields. Presets start empty: they do not pick fixed models or force request options. Unset or blank `provider` and `model` inherit the main backend/model (the current chat's model for the same backend, or the configured main model for another backend). Omitted request-option keys inherit from `request_options` for the resolved backend.

Each feature automatically uses a preset suited to its requests:

| Feature key | Requests | Default preset |
| --- | --- | --- |
| `tool_assessment` | Automatic tool safety/approval assessments | fast |
| `tool_review` | Interactive **Ask reviewer** questions and follow-ups | reasoning |
| `context_review` | Background per-turn context pruning | long context |
| `history_summary` | Descriptions generated by `:CodeitHistory` | fast |
| `compaction` | Both manual and automatic conversation compaction | long context |

Entries in `feature_settings` can select a different `preset` using its key. Omit `preset` to use the default above; set `preset = ''` to skip the preset. Features can still independently override `provider`, `model`, and `options`. Resolution is main backend settings → selected preset → explicit feature overrides. Unset or blank feature `provider`/`model` inherit from the preset. Changing a shared preset updates every feature using it, without affecting the main chat request.

The former `secondary_models` setting is no longer used. Old settings and chats still load, but that field is ignored; move any desired model choices into `model_presets` or `feature_settings`.

`options` override individual keys. Omitted keys inherit; `''` explicitly clears a key to the API default, even if the preset or main request has a value. OpenRouter supports `preferred_provider`, `service_tier`, and `effort`; Copilot supports `api_host`. Options belonging to the other backend are not sent. Presets and features may use a different backend from the main chat, so credentials/access for all selected backends are required. Explicit model IDs must match the resolved backend; if a feature overrides a preset's backend, also override its model when the preset has an explicit model.

In `:CodeitSettings`, select **Preset fast**, **Preset long context**, or **Preset reasoning** to edit shared settings. Select a feature to choose its preset and edit individual overrides. Model searches use the effective backend and API host; upstream-provider searches use the effective model. **Use inherited model** and **Inherit all request options** remove the current entry's overrides. **Reset preset to main chat settings** clears the shared preset; **Reset feature to its default preset** clears all of that feature's overrides and restores its default assignment. Return to the main menu and apply/save the draft. Changing only presets or feature settings preserves the conversation. Choose a long-context/compaction model with enough context capacity; automatic compaction thresholds still use the main model's limit. `context_review = false` remains the independent on/off switch for background pruning.

## Usage

### Command reference

| Command | Purpose |
| --- | --- |
| `:Codeit` | Toggle the chat sidebar |
| `:CodeitSend [message]` | Send a message, or the current draft when omitted |
| `:CodeitNew` | Start a fresh conversation |
| `:CodeitHistory` | Browse, resume, or delete saved chats |
| `:CodeitTasks` | View background tasks and logs, or cancel a running task |
| `:CodeitCompact` | Summarize completed turns for future requests |
| `:CodeitContext` | Inspect effective context and edit its summary |
| `:CodeitContextFull` | Edit the full effective request context as JSON |
| `:CodeitContextFiles` | Toggle instruction files and skills |
| `:CodeitSystemPrompt` | Edit the current conversation's system prompt |
| `:CodeitSettings` | Configure providers, models, presets, and request options |
| `:CodeitProvider openrouter` / `:CodeitProvider copilot` | Switch providers and start a fresh chat |
| `:CodeitTrust`, `:CodeitTrust all`, `:CodeitTrust tracked` | Trust workspace reads, interactively or directly |
| `:CodeitTrustStatus` | Show the workspace's trust mode |
| `:CodeitUntrust` | Revoke workspace trust |

### Background tasks

The assistant can use `start_background_task` for long-running commands. Starting
one uses the normal command approval flow and returns a task ID immediately;
you can continue chatting while the command runs. Commands operate on disk,
without implicitly saving buffers or invoking a shell. There is no timeout unless
the assistant supplies `timeout_ms`.

Open `:CodeitTasks` (or `/tasks`) to see this workspace's tasks. Select a task and
press `<CR>` to view its live stdout/stderr logs; press `<CR>` again to return.
Press `c` to cancel the selected task (including ordinary descendants on Unix),
and `q` or `<Esc>` to close the view. Logs retain the first 20000 bytes, with an
explicit truncation marker. Tasks and logs are session-only, survive closing or
switching chats, and running commands are stopped when Neovim exits.

The assistant can set `notify_on_completion = true` to request a follow-up.
After the task ends, the integration waits for the originating chat to be active
and idle, then asks whether to send its results to the assistant. Declining or
dismissing sends nothing. Approval never interrupts an active response or sends
results to a different chat. With this option omitted or false, no assistant
follow-up is requested; results remain available in the task view.

### Chat and navigation

In tool approval popups, file-edit/save previews, the tool-call reviewer, and tool-limit prompts, press `<C-g>` (normal or insert mode) to view the full chat transcript in a read-only popup. Scroll or search with normal Vim keys for context, then press `<C-g>`, `<Esc>`, or `q` to return. Switching views does not approve, reject, or dismiss the pending prompt; its cursor, scroll position, and any reviewer draft are preserved. The chat preview excludes your unsent message draft and works even when the sidebar is closed. Each visit shows the latest transcript and remembers your preview position.

`:Codeit` toggles the single chat sidebar. The transcript and the multiline draft under `## Message` share a Markdown buffer; assistant replies retain Markdown formatting. Type below the heading and press `<CR>` in normal mode or `<C-s>` in insert mode to send; `<CR>` in insert mode inserts a newline. Press `<C-g>` in normal or insert mode to toggle a large interactive chat popup (85% of the editor width, 80% of its height). It shares the sidebar's draft and live transcript, so sending messages and using slash commands works as usual. Press `<C-g>` again, or `<Esc>` in normal mode, to return to the sidebar. Press `q` in normal mode to close the chat, including its popup.

`:CodeitSend your question` sends a message directly. `:CodeitSend` sends the draft currently at the bottom of the chat.

#### Table previews

With the cursor on any row of a Markdown pipe table (header, separator, or body), press `gT` in normal mode to open an aligned, read-only table popup. This works in the sidebar and Codeit's Markdown preview windows. Columns respect left/right/center alignment and Unicode display widths; escaped pipes (`\|`) stay within their cells. Use normal Vim scrolling/search keys, including `zh`/`zl` for tables wider than the screen; press `q` or `<Esc>` to return. The original text is unchanged. Tables must have a header and a dash separator row; fenced code blocks are ignored.

#### Slash commands

In the chat draft, type `/` at the start of the message to open the slash-command completion menu. Press Tab to complete the first matching command; press it again to cycle through the matches from the first Tab. Choose an entry and press Enter to run it (or `<CR>` in normal mode). For `/provider` or `/send`, Enter accepts the completion first so you can type a required argument; press Enter again to run it. Command results stay in chronological order in the chat transcript and are saved with its history, without being sent to the assistant. Slash names are the Ex command names without `Codeit`, starting with a lowercase letter: for example, `/compact`, `/contextFull`, `/systemPrompt`, `/trustStatus`, and `/toggle` (for `:Codeit`). Commands with arguments also work, such as `/provider copilot`, `/trust tracked`, and `/send your question`. A single-line draft starting with `/` is treated as a command, not sent to the assistant; unknown commands remain in the draft for correction. Multiline messages and slashes elsewhere in a message are sent normally.

### Tool-round limits

When the assistant reaches `max_tool_rounds` (default 12) and requests more tools, a popup pauses the turn: press `1` to allow another configured allowance, `2` to enter a custom positive whole number, or `3` / `<Esc>` to decline. Enter selects the highlighted choice. A **round** is one assistant tool-call batch, which may contain multiple calls. Extra rounds apply only to the current turn; exhausting them prompts again, and individual tool approval policies still apply. Declining (including closing the popup or cancelling custom input) returns a limit error for each pending call and requests one final response with tools disabled. Setting `max_tool_rounds = 0` prompts before the first tool batch and offers only custom continuation or decline.

### Background context review

After a completed user turn with at least `context_review_min_tokens` (default 512) estimated tokens of replaceable tool exchanges, the `context_review` feature model reviews that turn asynchronously, without tools, and prunes low-value tool context in the background. Turns without eligible tool exchanges are never reviewed. Short useful outputs stay verbatim; long responses, bulky edit arguments, and ephemeral information can be replaced with concise factual notes recording what was actually done, relevant paths, results, failures, and remaining work. User messages, assistant prose, clarification answers, and skill instructions are preserved. Calls and results are removed together, so retained exchanges remain valid. The full visible transcript stays unchanged; review decisions are saved with the chat and survive resume. `:CodeitContext` and `:CodeitContextFull` show the effective reviewed context. You can send another question while review is pending: all tool rounds in the active user turn keep the same review snapshot; the next user turn uses newly available reviews. Stable instruction and skill messages precede the changing summary to improve prefix-cache reuse. Stale reviews after reset, workspace changes, manual context edits, or compaction are ignored; failed/invalid reviews leave context unchanged. Review requests may incur provider charges (included in OpenRouter usage totals). Set `context_review = false` in `setup()` to disable this independently of automatic compaction.

### Conversation compaction

`:CodeitCompact` summarizes older completed turns using the `compaction` feature's backend/model, without tools, preserving the most recent completed turn verbatim by default. `:CodeitCompact!` (or `require('codeit').compact(true)`) includes all completed turns. Future requests send stable instructions, the summary, and newer turns; the full transcript remains visible and saved. Summaries use structured goals, decisions, implementation, verification, and unresolved-work sections, removing superseded facts. Empty, oversized, or non-reducing summaries leave context unchanged; they are never blindly truncated. Compaction is unavailable during a response or an unfinished turn. Its summary and checkpoint survive resume. Summary requests may incur provider charges, including rejected summaries.

Automatic compaction detects the main model's limit from OpenRouter or Copilot metadata, cached per provider/model/API host. `max_context_tokens` overrides detection; `false` disables automatic compaction without disabling manual compaction. Unavailable metadata leaves automatic compaction disabled with a warning. Scheduling triggers at 75% uncompacted growth (including instructions and tool schemas), or when the **full request including the existing summary** reaches its safe input budget. That budget reserves up to 4096 output tokens (capped at 15% of the window) plus a 5% estimation margin. Checkpoints target roughly 50% retained context and enough room for the replacement summary; oversized active turns may force more older turns to be summarized. An active user/tool turn is never split. If fixed context or the active turn still exceeds the budget, the request automatically switches to the `long_context` preset only if provider metadata confirms that its safe input budget can fit the full request (including tool schemas). That preset is retained for subsequent tool rounds in the same user turn without changing the configured main model. If the preset cannot fit or its metadata is unavailable, a warning is shown and the original model is used best-effort. Failed compaction sends the original context without retrying in the same request.

Token counts remain estimates at four JSON bytes per token, not exact provider tokenization. Summaries default to at most 2048 estimated tokens including message framing, capped at 25% of the main window for automatic compaction. The compaction model's own window is checked independently; oversized transcripts are processed in turn-aligned batches, committing only after all batches succeed. Private reasoning metadata is excluded. If a single completed turn cannot fit, compaction automatically tries the `long_context` preset, bypassing compaction feature overrides, only when its reported window can fit that turn, the previous summary, the summarization prompt, and reserved output. Remaining batches use the fallback; if it cannot fit or its metadata is unavailable, compaction fails safely without committing partial summaries. If feature-model metadata is unavailable, its input window cannot be enforced.

Configure these policies in `setup()`:

```lua
compaction = {
  summary_tokens = 2048,
  output_reserve = 4096, -- capped at 15% of the main context window
  manual_keep_turns = 1, -- 0 restores compact-all behavior
},
context_review_min_tokens = 512, -- 0 reviews every eligible tool turn
```

Cached-input usage is normalized for both providers. The chat displays `Cache: N%` when the provider reports it (over observed main-request input only). `require('codeit').context_stats()` returns persisted cache totals, main-request counts, and compaction records with estimated before/after sizes (excluding schemas), duration, pass count, reported cost, checkpoint, and failure reason. These measurements support threshold tuning; they are not a guarantee of cache hits or summary quality.

### Instruction and skill selection

`:CodeitContextFiles` (or `/contextFiles`) opens a picker showing eligible instruction and skill files and their paths. Press `<CR>` to toggle instructions between `[on]` and `[off]`, or cycle skills **off → on → active → off**; press `q`/`<Esc>` to close. Global and root instructions are on by default; nested instructions appear after the assistant accesses a file beneath their directory. Skills default to `[on]`: only their name and description are advertised, and the assistant can call `load_skill` to make them `[active]`. Active skills include their full instructions in context. `[off]` hides the skill's name, description, and instructions and prevents `load_skill` from loading it. Changes take effect on the next request, survive resuming the chat, and reset on `:CodeitNew` or workspace/provider changes. State changes are unavailable while a response is in progress and cannot override workspace trust. Returning a skill to on or off also redacts its earlier `load_skill` instruction results from future requests; off additionally hides the skill name in those calls' arguments. The saved transcript stays visible and is not rewritten. Existing compacted summaries, assistant prose, or manually inserted copies of skill information are not removed automatically.

### Inspecting and editing context

`:CodeitContext` shows the effective message context for the next request: system prompt, compacted summary (if present), and newer turns. Edit the summary and press `:w` or `<C-s>` to save it for future requests; press `q` to close. Other sections cannot be changed on save. Compact first if there is no summary. Edits persist when resuming the chat.

`:CodeitContextFull` opens the **entire effective request context** as editable JSON (including system prompt, summary, messages, and tool metadata). Edit the message array and press `:w` or `<C-s>` to save, or `q` to close. The first entry must be a nonempty system prompt; tool calls must have matching results. Saving replaces the transcript with this effective context, clears display-only command results, and clears the compaction checkpoint: earlier compacted turns are no longer in the chat, while the summary becomes an ordinary system message. Changes are saved to history and sent on the next request. Invalid JSON or changes to an out-of-date view are rejected.

#### System prompt

`:CodeitSystemPrompt` opens a plain-text editor for the current conversation's system prompt. Save with `:w` or `<C-s>`; an empty prompt is rejected. Changes to an existing chat persist across resume. Before the first message, the override applies only to this session; `:CodeitNew`, switching providers, or changing workspaces resets it to the configured prompt.

### Chat history

`:CodeitNew` starts a fresh conversation and cancels outstanding responses or
pending edits; previous chats remain in history.

`:CodeitHistory` lists saved chats for the current workspace (most recently updated first), showing each chat's last-updated date/time and LLM summary. For chats whose latest assistant turn has finished, it generates a brief description of what was done using the currently active `history_summary` feature settings, not the saved chat's settings, before opening the picker. Each successful summary is cached in the chat file. Sending another question clears that cache; once the new turn finishes, history generates a fresh summary. Unfinished chats are shown with just their date/time. Select a chat in the wide, scrollable history window with `<CR>` to resume its transcript, provider, model, and usage totals; press `d` to permanently delete the selected chat after confirmation, or `q` / `<Esc>` to dismiss the window. Deleting keeps the history window open. If you delete the current chat, its open transcript remains available but is detached from the deleted entry; sending another message saves it as a new chat. The current chat cannot be deleted while a response is in progress. Summary requests may incur provider charges and are not included in the chat's usage totals.

## Settings

`:CodeitSettings` (or `/settings`) opens a highlighted, cursor-driven settings window, grouped into main chat, request options, shared presets, feature overrides, and apply/save actions. Move with `j`/`k` or arrow keys and press `<CR>` to select; normal Vim scrolling and `/` search also work. Headings are not selectable. Long values can be scrolled horizontally with `zh`/`zl`. Returning from an edit remembers the selected row. Press `q` or `<Esc>` to go back from a submenu, or discard the draft from the main window.

**Browse models** loads the selected backend's catalog directly, sorted by model ID, with names and descriptions available for Vim search. Cancel to return without changing the model. You can also enter a model ID manually. Settings choices use Codeit's own window rather than an installed fuzzy picker; text entry still uses `vim.ui.input`. Catalog access requires the backend's credentials; choosing a model does not guarantee tool-calling support or account access. Changes remain a draft until you choose **Apply for this session**, **Apply and save globally**, or **Apply and save for this workspace**. Each preset and feature has its own submenu, described above. Changing the main backend/model starts a new conversation (the old one stays in history); changing only presets, feature settings, or request options preserves the current chat. Settings cannot be changed while a response is in progress.

Highlight groups `CodeitSettingsHeading`, `CodeitSettingsLabel`, `CodeitSettingsValue`, `CodeitSettingsHint`, and `CodeitSettingsAction` use colorscheme defaults and can be overridden with `nvim_set_hl`.

### Persistence and precedence

Saved provider/model settings use this precedence: `setup()` defaults/options < saved global settings < saved workspace settings. Each save stores a complete provider/main model/presets/feature settings/options snapshot, including cleared options. Legacy snapshots missing presets or feature settings inherit those settings from lower-precedence defaults; an explicit empty map clears them (empty feature settings restore default preset assignments). Workspace settings are keyed by the resolved working-directory path in `stdpath('data')/codeit/settings.json`, not in the repository; the file is written atomically with mode `0600` and contains no credentials. Saved defaults load on setup and workspace changes; session-only changes last until setup or a workspace change. Saving globally applies immediately, but does not delete an existing workspace override, which will win when that workspace's defaults are next loaded. Saved chats also retain their presets, feature settings, and request options; resuming restores them along with the saved backend/main model. Older chats missing presets or feature settings keep the current defaults for those settings.

### Provider request options

OpenRouter settings include **Preferred upstream provider** (loads endpoints for the selected model and lists provider names, routing tags, and input/output prices in USD per million tokens; nonzero per-request charges and quantization are also shown when reported). Selecting an endpoint uses its exact routing tag as `provider.order`; fallbacks remain enabled. Prices are current catalog rates, not a total quote: caching, media, other charges, tier selection, and fallback routing can change actual cost. Missing prices show as `unknown`. The picker also offers automatic routing (clear the preference) and manual slug entry, even if endpoint lookup fails. Other options include **Service tier** (`default`, `flex`, `priority`, `fast`, `ultrafast`), and **Reasoning effort** (`none`, `minimal`, `low`, `medium`, `high`, `xhigh`, sent as `reasoning.effort`). Blank values omit the parameter and use the provider default. These per-backend defaults apply to main chat and are inherited by features using that backend; per-feature `options` override individual keys. Support and pricing depend on the selected model/upstream provider; priority tiers can cost more, flex can be slower, and unsupported options may be ignored or rejected by the API. Copilot additionally offers **Copilot API host** for standard/business routing, but these OpenRouter-specific request options are not sent to its undocumented API.

`:CodeitProvider openrouter` / `:CodeitProvider copilot` switches providers and starts a fresh conversation.

Chat and model-metadata requests automatically retry HTTP 429 rate-limit responses up to three times. Retries honor `Retry-After` (seconds or an HTTP date); absent or invalid headers use delays of 2, 4, and 8 seconds. If the server requests a wait longer than 60 seconds, or retries are exhausted, the request ends with an error so you can retry manually later. Other HTTP errors, transport failures, and invalid successful responses are not retried. Copilot credential exchange does not use these retries.

## Storage, usage, and logs

### Workspace and chat persistence

Closing the sidebar does not discard the conversation. `read_source_buffer` targets the ordinary buffer active when the sidebar was opened (including an unnamed buffer); `read_file` requires a workspace `path`, and `read_loaded_buffer` requires a loaded `buffer_id`. `edit_file` and `save_buffer` require a workspace path; `edit_loaded_buffer` / `save_loaded_buffer` take a loaded buffer ID, and `edit_source_buffer` / `save_source_buffer` use the source buffer. Agent workspace tools use Neovim's current working directory as the workspace root. Chats are saved automatically as they change under `stdpath('data')/codeit/chats/`, separated by resolved workspace path; files have mode `0600`. Changing workspaces starts a fresh chat without deleting the previous workspace's history. `:CodeitHistory` resumes a saved chat; incomplete tool-call batches from interrupted sessions are discarded on resume and are never re-executed. Main chat responses stream live text into the transcript and assistant pane. Partial responses are display-only: only complete responses are saved or used to execute tool calls. Failed or interrupted streams are not retried automatically. Compaction, reviews, and summaries remain non-streaming.

### Cost and token usage

The chat's cost/token usage line stays visible at the top of the transcript as you scroll. For OpenRouter and Copilot it shows session cost in USD, cumulative input (`In`) and output (`Out`) tokens in millions (`m`) across chat and reviewer requests, and the latest main-chat response's context length (`Context`) in thousands (`k`; from `total_tokens` or input + output tokens). Immediately after background context pruning, compacting, or editing the summary, `Context` updates to an approximate size of the effective message context, marked with `~`; the next main-chat response replaces it with reported usage. The estimate excludes tool definitions and uses roughly four characters per token. Displayed numbers have at most three decimal places. A `+` after a total means some requests omitted that usage field; `—` means the latest context is unavailable. Copilot cost comes from the server's `copilot_usage.total_nano_aiu`, converted to USD (one billion nano-AIU = one AI credit = $0.01); no catalog-based estimate is substituted when the charge is missing. Both Copilot and OpenRouter feature requests contribute cost/tokens regardless of the main chat's provider. `:CodeitNew`, switching providers, and `setup()` reset these figures for the new chat; resuming a saved chat restores its figures. Closing and reopening the sidebar preserves them.

### Error logs

Provider chat errors and context-limit metadata lookup errors are appended to `stdpath('state')/codeit/provider-errors.log` (new files use mode `0600`). Entries include the provider/model, timestamp, error, and any failed HTTP response body for debugging. This file may contain sensitive response data; handle it accordingly.

Failed tool calls are automatically appended as one JSON object per line to `stdpath('state')/codeit/tool-errors.jsonl`. Each entry includes the UTC invocation `timestamp`, `integration_commit` (the plugin's Git HEAD, **not** the workspace's; `null` if Git metadata is unavailable), `tool`, `arguments`, and the exact `error` result returned to the model. Chat calls also include `tool_call_id` and `raw_arguments`, preserving malformed JSON for analysis. Time and commit are captured before approval/execution, including for calls declined at the tool-round limit. Validation errors, execution exceptions, approval rejections, command/Git failures, and timeouts are logged; successful calls, ordinary searches with no matches, deferred calls, and cancelled/stale tasks are not. The directory uses mode `0700` and the log `0600`; logging failures warn once without changing tool results. This is a local log with no automatic upload or rotation: delete/archive it manually as needed. **Arguments and errors are stored verbatim and may include secrets or source code; review/redact before sharing.**

## Project instructions and skills

When the current workspace has been trusted with `:CodeitTrust all` or `:CodeitTrust tracked` (or via `approval.trusted_workspaces`), requests include Markdown instructions from `~/.claude/` and `~/.config/codeit/` first, then from the workspace root. Both `CLAUDE.md` and `AGENTS.md` are recognized case-insensitively; both are included when present. Instructions in subdirectories become active after the assistant reads a file beneath them, including buffer tools, or proposes a write there. If new instructions or a selected skill become active during a tool batch, the remaining calls are deferred with matching tool results so the assistant can reconsider them on its next request. A write that discovers new instructions is not applied until reissued after that review. Those relevant directories remain active for that chat, including on resume. Instructions from nested directories are ordered from parent to child. Trust revocation immediately stops automatic inclusion. In `tracked` mode, workspace instructions and skills must be Git-tracked; in `all` mode untracked ones are allowed. Global instructions and skills are included when the current workspace is trusted in either mode. Symlinks escaping the corresponding instruction tree, binary files, and files larger than 100 KB are not loaded.

Skills are discovered under `.agents/skills/<name>/SKILL.md` and `.claude/skills/<name>/SKILL.md` in the workspace, plus `~/.agents/skills/`, `~/.claude/skills/`, and `~/.config/codeit/skills/`. The `SKILL.md` filename is recognized case-insensitively (for example, `skill.md` also works). Global skills use the same per-chat on/off toggles in `:CodeitContextFiles` as workspace skills. A skill's YAML frontmatter `description` (or its directory name) is advertised to the assistant. The read-only `load_skill` tool is advertised only when the trusted workspace has at least one enabled, available skill (including global skills). This is reevaluated before each request as trust or context-file toggles change. The assistant can call it to select a skill; its full instructions are then available for the remainder of the chat unless turned off in the context-files picker. Calls for unavailable or disabled skills return an error without an approval prompt. If names collide, workspace skills take precedence over global skills. Supporting files and scripts are **not** loaded or executed automatically; the assistant must use ordinary workspace tools subject to their usual approval rules to access them.

Instructions and selected skills are read afresh before each model request. They are separate from the saved base system prompt and compacted transcript, and are visible in `:CodeitContext` and `:CodeitContextFull`. Editing `:CodeitSystemPrompt` changes the base prompt but does not disable these instructions. Saving `:CodeitContextFull` replaces the effective context with the edited message array and clears the current file/skill selections and toggle choices; future requests may discover and add trusted instructions again. Trust controls automatic inclusion, not tool reads explicitly approved by the user. Avoid trusting projects whose instruction files you would not want sent to the configured provider.

## Agent tools

The assistant can:

- List and search workspace files (`list_workspace_files`, `search_workspace`; requires `rg`), and read files with `read_file` (required workspace `path`), `read_loaded_buffer` (required loaded ordinary `buffer_id`), or `read_source_buffer` (no target arguments). These tools have disjoint target fields, so never pass both a path and an ID. Unnamed buffers and unsaved new-file buffers can be addressed by ID. `list_buffers` lists only loaded ordinary workspace buffers by default, with a `source` flag; external or unnamed source buffers are hidden unless `include_external = true` explicitly requests all ordinary buffers through approval. Listings accept an optional existing workspace `directory`, filter before pagination, and return `{ files, total_matches, truncated, next_offset }`; paths remain workspace-relative. Searches accept the same `directory`, an optional filename/path `glob` (e.g. `*.lua`, `src/*.lua`, or `!*.lock`; simple Vim glob syntax without brace alternatives), and `context_lines` from 0–20. Globs filter results after ignore rules, so they do not reveal ignored files. Match lines use `path:line:text`, context lines use `path-line-text`; exit code 1 means no matching results. For listings, use `offset = next_offset` to continue. Pages contain at most 200 paths / 20 KB of encoded path data. Searches use disk contents, not unsaved buffers, and skip ignored/binary files, files over 1 MB, and lines over 300 columns. Reads include unsaved buffer contents; clean buffers refresh from disk. Each read tool returns at most 200 lines / 20 KB of encoded line data, with `path`, `buffer_id`, `total_lines`, `modified`, `truncated`, and `next_start_line` for continuation. Explicit ranges have the same bounds; ranges beyond EOF return available lines. Individual lines exceeding the byte limit return an error rather than partial source text.
- Edit existing files by workspace `path` with `edit_file`, by loaded `buffer_id` with `edit_loaded_buffer`, or edit the source buffer without a target using `edit_source_buffer`. Create new files with `create_file`. Pass an `edits` array for every call, even for one replacement: `edits = { { old_text = ..., new_text = ... } }`. It accepts 1–50 entries; `old_text`, `new_text`, `start_line`, and `end_line` are only allowed inside entries. Every `old_text` must be nonempty and match exactly once in the **original revision**; optional `start_line` **and** `end_line` on each replacement scope that match to an inclusive line range. Missing, ambiguous, out-of-range, or overlapping edits reject the entire batch before approval. Valid batches receive one combined preview and are applied in one buffer update; replacements cannot depend on another replacement's output. Replacements use exact-text semantics, not whole-line deletion: include the newline in `old_text` when removing a line. Existing-file edits are saved automatically when the target buffer was clean before the edit. If it already had unwritten changes, the agent's edit remains unsaved alongside them for review and manual saving in Neovim. Write failures are reported and leave the edit in the buffer. Existing-file edits in chat require a read of the current revision (or the revision produced by an earlier approved edit); after resume or external changes, read again. Edits also check disk changes while approval is pending. The edit tools work on large files as well as unnamed buffers; combined `old_text` and `new_text` across a call are limited to 200 KB, but there is no 200 KB file-size or 200-line edit-range limit. Batch atomicity covers validation and buffer mutation, not filesystem write hooks: if saving fails, the complete edited buffer remains available for review. Unnamed buffers are never automatically saved. New files are created on disk in existing directories with content up to 200 KB, unless a buffer for that path already has unwritten changes; existing clean buffers are refreshed after creation.
- Ask a necessary clarification using `ask_user`: a nonempty, optionally multiline `question` (up to 2000 bytes), optional 0–10 single-line `choices` (up to 200 bytes each), and an **Other** free-text answer option. The question is displayed as Markdown inside a near-full-screen popup, matching the other integration dialogs. Select choices with `1`–`9` / `0` (tenth choice) or normal-mode Enter; `o` opens a free-text answer with the question still displayed. Free-text answers support multiple lines: insert-mode Enter adds a newline, Ctrl-S or normal-mode Enter submits a nonempty answer, and normal-mode Esc cancels the task. Ctrl-G opens chat context and returns to the question. The task pauses until answered; remaining calls in that batch are deferred so the model can consider the answer before proceeding. Dismissal cancels the task, and stale answers after a reset are ignored. Questions should not replace project inspection, and answers are not write/save approvals. Reject validators still apply; there is no redundant approval or reviewer request for the question itself.
- Save a named loaded ordinary buffer by workspace `path` with `save_buffer`, by ID with `save_loaded_buffer`, or use `save_source_buffer` for the source buffer. It previews disk versus buffer contents and explicitly saves **ALL current changes, including the user's edits**. Every save requires approval once, even with trusted workspaces, saved approvals, or approve validators; reject validators still apply. No **Always approve** option is offered. It does not name unnamed buffers, load unopened files, or force external overwrites. Pending disk/buffer changes invalidate approval. Saving uses normal Neovim write hooks; errors retain unsaved changes. This is never performed implicitly before tests.
- Run builds, tests, or linters via `run_command` (argument vector, no implicit shell), inspect loaded-buffer diagnostics (`get_diagnostics`; omit `path` or pass `""` for all loaded workspace files), and inspect workspace Git changes (`git_status`, `git_diff`). `get_diagnostics.wait_ms` optionally waits 1–5000 ms for a matching `DiagnosticChanged` event, returning `{ diagnostics, truncated, updated, timed_out, waited_ms, note }`; omitted/zero waits retain the existing array response. It observes updates without triggering tests, saves, or linters. An update is not proof of a complete/fresh check, and an empty list does not prove success. Cancellation cleans up the wait. Commands and Git inspect disk files, not unsaved buffers. Git diff defaults to unstaged tracked changes, including deleted paths, not untracked files; `staged = true` compares the index to HEAD. Optional `base` compares the working tree to a single commit revision such as `HEAD` or `main`, or compares the index to that revision when combined with `staged = true`. Revisions are verified before diffing, and ranges or option-like arguments are rejected. Omit `path` or pass `""` to see all workspace diffs (both have identical approval behavior). Git tools disable external diff, text-conversion, and filesystem-monitor programs and treat path filters literally. Commands accept 1–40 arguments of at most 4096 bytes each; the executable must be nonempty, but subsequent empty arguments are allowed.
- Fetch HTTP(S) URLs using `fetch_url` (`curl` required). Results report the HTTP status, final URL after redirects, and a body limited to 20 KB; non-2xx or transport errors are explicitly reported. Fetches can reach localhost/private networks and are **not** a public-network sandbox; they always use ordinary approval policy. Curl configuration files are disabled, redirects are restricted to HTTP(S), and requests time out after 15 seconds. This is not a web search engine or an MCP integration.

`read_buffer` and `replace_buffer_lines` are no longer exposed or executed. Saved transcripts remain readable; if an older chat attempts an obsolete tool, it receives an error directing it to the unified tools. Update approval validators that matched those names to match `read_loaded_buffer` / `read_source_buffer` for buffer reads, or `read_file` for path reads; approvals saved for the removed names do not transfer. Calls that previously used `read_file` with `buffer_id` (or without a target) must now use `read_loaded_buffer` (or `read_source_buffer`); corresponding saved approvals and validators should be updated as well. Likewise, `edit_file` and `save_buffer` now only accept `path`; buffer-ID and source calls must switch to the appropriate target-specific tool. Remembered approvals for the old names do not carry over to the new ones.

## Trust and approvals

### Workspace trust

`:CodeitTrust` prompts you to trust the current workspace for **all files** or
**Git-tracked files only**. Use `:CodeitTrust all` / `:CodeitTrust tracked` to
choose directly, `:CodeitTrustStatus` to inspect the mode, or `:CodeitUntrust`
to revoke it. Choices persist across Neovim sessions.

Read tools require approval by default. Use `:CodeitTrust` to trust Neovim's current working directory interactively; choices are stored in `stdpath('data')/codeit/trusted_workspaces.json` (mode `0600`). You can also set `approval.trusted_workspaces` to a map of absolute workspace directories to `'all'` or `'tracked'`; choices made with the commands override configuration for that workspace, including `:CodeitUntrust`. Trust applies only when the current workspace resolves to that directory; it does not extend to parent or child workspaces. In `'all'` mode, reads of files physically inside that workspace are auto-approved, including untracked files. In `'tracked'` mode, individual file/buffer reads are auto-approved only for Git-tracked files. Workspace-wide searches and file listings, unfiltered diagnostics, and Git status still ask in `'tracked'` mode because they can expose untracked content or names; Git diff and diagnostics for a tracked file are auto-approved. Default buffer listings are auto-approved in `'all'` mode, including named workspace buffers for files not yet saved to disk. In `'tracked'` mode, they ask if any returned buffer is not an existing Git-tracked file. External or unnamed source buffers do not affect default listings or their approval. Broader `include_external = true` listings are never auto-approved by workspace trust (explicit validators or remembered calls can still approve them). Symlinks to files outside the trusted workspace always ask. Trust is granted explicitly; there is no implicit trust for the plugin's own directory.

### Approval previews and reviewer

Edits, creation, explicit saves, commands, and URL fetches require approval in either mode; unknown or removed tools return an error without executing. Standard Markdown approval prompts show the tool name in bold above formatted arguments: pretty-printed JSON for ordinary calls, or a shell-quoted `bash` fence for `run_command`'s argument vector (shown for readability; the command is still executed without an implicit shell). Eligible non-write calls make a separate tool-free reviewer request to summarize the call and assess its safety. Workspace reads (including searches, listings, diagnostics, and Git tools) skip this automatic assessment even when approval is required; external or unnamed buffer reads and broader buffer listings can receive one. When requested, the summary is shown in the Markdown approval window (bold if unsafe), or marked unavailable if review fails. **Ask reviewer** remains available on workspace-read prompts.

Write calls (the edit/save variants and `create_file`) instead open a dedicated popup without waiting for an automatic summary. It shows the entire proposed file with source syntax highlighting; removed lines appear in red next to added lines in green, without patch headers or `+`/`-` prefixes. Centered virtual text keeps the approval shortcuts pinned to the top while scrolling; the preview opens at the first changed region; `{` and `}` jump between changed regions, wrapping at the ends. Press `<CR>` in normal mode (or `1`) to approve the file edit once. Press `5` to ask the tool-free reviewer about the change (`4` on save previews, which omit **Always approve**); it receives the proposed patch, and returning from the reviewer brings back the full-file preview. Review is advisory and never auto-approves a call. Automatic assessments are prefetched before approval validators run, so eligible calls can incur assessment charges even if a validator later rejects or auto-approves them. Calls with remembered exact-call approvals skip automatic assessments.

In the standard Markdown approval window, move to a choice and press `<CR>` in normal mode to select it, or use the number shortcuts: `1` **Approve once**, `2` **Always approve exact call**, `3` **Reject** (with an optional explanation sent back to the agent), and `4` **Cancel task**. On read-tool prompts, `5` **Trust workspace (Git-tracked reads)** or `6` **Trust workspace (all reads)** saves that choice for the current workspace and approves the pending read; it does not auto-approve edits or commands. **Ask reviewer** is `5` on other prompts and `7` on read prompts when available. Press `<Esc>`, or close the approval window, to reject the call.

The reviewer opens a single Markdown window showing the tool name, arguments, conversation, and a multiline draft under `## Question`. Type below the heading and press `<C-s>` (in insert or normal mode), or `<CR>` in normal mode, to send. A waiting indicator appears until the reply is added to the conversation. Type another question below the heading to follow up. Press `<Esc>` in normal mode or close the reviewer window to return to approval; empty questions are ignored. The reviewer is a separate, tool-free conversation with the configured model. Cancelling stops the task and drops its unfinished tool-call batch, leaving earlier conversation intact.

When the assistant has provided an explanation during the current user turn, approval previews, reviewer windows, and clarification popups show its latest nonempty text in a separate read-only Markdown pane above the popup. Tool-only replies preserve that explanation; a new user message clears it. The pane wraps text and reserves at most roughly 30% of the editor height, shrinking the decision popup when necessary. Keyboard focus stays on the decision or answer field, and the pane closes when that interaction finishes. Very small editors (fewer than 10 lines) omit the pane. Clarifications still use `vim.ui.select` / `vim.ui.input`: floating pickers are repositioned to make room, while command-line prompts get a pane at the top of the editor. Third-party multi-window pickers that enforce their own layout may override that positioning.

### Remembered approvals and validators

Always-approved signatures include the workspace's resolved path, tool name, and full arguments (independent of JSON object key order); their hashes are saved across Neovim sessions in `stdpath('data')/codeit/approvals.json`. Explicit per-call approvals remain effective even if workspace trust changes; delete that file to revoke saved approvals. Configure `approval.validators` in `setup()` with functions receiving `(name, args, context)` that return `'approve'`, `'ask'`, `'reject'`, or `nil`, optionally with a reason. Validators run for **every** call, including saved approvals and `ask_user`; all save tools require their own explicit approval window, even for an approve decision. Rejection wins over asking, and asking wins over approval or saved/default auto-approval. Errors or invalid decisions reject the call.

### Execution boundaries

Buffer edits check for changes while confirmation is pending; file paths are restricted to the current workspace, including symlink targets. Commands run in that workspace but, once approved, can access the wider system. Command/search/Git outputs are limited to 20 KB with explicit truncation markers. Commands time out after 60 seconds; cancellation and timeout send SIGTERM, then SIGKILL after a grace period. On Unix, signals reach the process group and ordinary descendants; processes that deliberately detach can escape, and other platforms only terminate the direct process. Cancellation cannot undo side effects already completed. File reads and listings are bounded and advertise continuation rather than silently appearing complete. Invalid tool arguments and execution exceptions return tool errors so the assistant can recover. This is a local approximation of common VS Code Copilot Agent capabilities, not VS Code's exact or extension-provided tool set.

## Development

Run all headless tests from the repository root:

```sh
sh tests/run.sh
```

The runner isolates saved approvals and state in temporary directories and exits
with an error if a suite fails.

## License

Licensed under the [MIT License](LICENSE).
