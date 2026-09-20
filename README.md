# jev-router.nvim

An intent router for Neovim that classifies AI commands with
[Jev](https://docs.typesafe.ai) (TypeSafe's System One model) via the
[OpenRouter Decisions API](https://openrouter.ai/docs/api/api-reference/alphadecisions/submit-a-decisions-questions-and-answers-request),
then routes execution to the matching handler.

The plugin sends the user's prompt as `state`, asks Jev a single `choice`
question (`intent`), and maps the result to one of four routes:

| Intent            | Meaning                                              |
| ----------------- | ---------------------------------------------------- |
| `read_file`       | Open the file the prompt refers to (semantic)        |
| `edit_code`       | Modify / write code in the active buffer             |
| `run_command`     | Run a terminal command (tests, build, ...)           |
| `general_question`| A broad question needing no file context             |

## Requirements

- Neovim **0.10+** (`vim.system`), and `curl` on `$PATH`.
- `git` for file-candidate discovery (`read_file` falls back to `find` if absent).

## Install (lazy.nvim)

```lua
{
  "Mawfyy/jev-router.nvim",
  opts = {
    -- api_key = "sk-or-...", -- or set OPENROUTER_API_KEY in your environment
    confidence_threshold = 0.6,
  },
}
```

No external Lua dependencies are required.

## API key

The plugin reads `OPENROUTER_API_KEY` from your environment. The easiest way is
an `.env` file (loaded automatically from the plugin root, your working
directory, or your Neovim config directory):

```bash
# ~/.config/nvim/.env  (or .env in your project root)
OPENROUTER_API_KEY="sk-or-v1-..."
```

Or export it in your shell, or pass `api_key` explicitly to `setup`. Prefer the
`.env`/environment approach so the key never ends up in your git history.

## Setup

```lua
require("jev-router").setup({
  -- api_key is optional; OPENROUTER_API_KEY is read as a fallback.
  api_key = "sk-or-...",
})
```

Full options:

```lua
require("jev-router").setup({
  timeout_ms           = 30000, -- per-request timeout
  confidence_threshold = 0.6,   -- route below this confidence = uncertain

  on_error    = function(err) vim.notify("[jev-router] " .. err, vim.log.levels.ERROR) end,
  on_uncertain = function(intent, confidence)
    vim.notify("[jev-router] uncertain " .. intent, vim.log.levels.WARN)
  end,
})
```

## Usage

```vim
:JevAsk open the file related to config
:JevAsk rename this function to greet
:JevAsk run the test suite
:JevAsk what does this plugin do
```

```
:JevAskBuffer [optional prompt]
```

The `read_file` intent is implemented natively: it semantically resolves which
file the prompt refers to (via a follow-up Jev Choice question over candidate
files), then opens it in a vertical split with line numbers. Candidates are
open buffers plus `git ls-files` output. When Jev's confidence is too low, or
the API is unavailable, it falls back to a `vim.ui.select` picker.

The `run_command` intent is implemented natively: it asks a chat model to
generate a single shell command for the prompt (with the working directory as
context), previews it in a `vim.ui.input` prompt for you to edit/confirm, then
runs it in a bottom terminal split.

The `general_question` intent is implemented natively: Jev's parallel
`complexity` judgment (quick vs deep) picks a chat-model tier, the handler
injects bounded project context (active buffer, file tree, key files), and the
answer is shown in a floating window (press `q` or `<Esc>` to close).

The `edit_code` intent is implemented natively: it sends the current buffer and
the request to a chat model, which returns the full updated file. The handler
shows a `vimdiff` preview and applies the change only after you confirm.

All four intents (`read_file`, `edit_code`, `run_command`, `general_question`)
are implemented natively. Override any of them via `route_handlers` in `setup`:

```lua
require("jev-router").setup({
  route_handlers = {
    run_command = function(prompt)
      vim.cmd("botright term " .. vim.fn.shellescape("make test"))
    end,
  },
})
```

## Extensibility

Two seams let you swap the underlying implementations without touching the
handlers: `chat_backend` (how the plugin talks to a chat model) and
`file_provider` (how it discovers project files). Both default to the built-in
implementations (OpenRouter chat client, `git ls-files` + open buffers).

```lua
require("jev-router").setup({
  -- Route chat to any OpenAI-compatible endpoint (or a local model).
  chat_backend = function(models, messages, callback)
    -- models: string | string[] (ordered fallback)
    -- messages: { { role = "...", content = "..." }, ... }
    -- callback: fun(text: string|nil, err: string|nil)
  end,

  -- Custom file discovery (e.g. LSP workspace folders, a monorepo indexer).
  file_provider = {
    list = function(callback)
      -- callback: fun(paths: string[])  -- absolute file paths
    end,
  },
})
```

This is also what the test suite uses to inject fakes and avoid network calls.

| Option                | Type     | Default                                          | Description                                        |
| --------------------- | -------- | ------------------------------------------------ | -------------------------------------------------- |
| `api_key`             | `string` | `$OPENROUTER_API_KEY`                            | OpenRouter API key                                 |
| `endpoint`            | `string` | `https://openrouter.ai/api/alpha/decisions`      | Decisions endpoint                                 |
| `model`               | `string` | `typesafe/jev-1.13`                             | Model alias                                        |
| `chat_model`          | `string` | `openai/gpt-4o-mini`                             | Chat model for command/answer generation           |
| `chat_models`         | `table`  | `{ quick = {...}, deep = {...} }`                | Tiered models (fallback order) for `general_question` |
| `chat_endpoint`       | `string` | `https://openrouter.ai/api/v1/chat/completions` | Chat-completions endpoint                          |
| `chat_backend`        | `function` | built-in OpenRouter chat client                 | Custom chat backend (model, messages, callback)    |
| `file_provider`       | `table`  | git + buffers                                   | Custom file provider `{ list = function(callback) }` |
| `context_max_files`   | `integer`| `200`                                            | Max files listed in injected context               |
| `context_max_chars`   | `integer`| `20000`                                          | Max injected context characters                    |
| `context_key_files`   | `string[]`| `{ "README.md" }`                               | File basenames always injected as context          |
| `timeout_ms`          | `integer`| `30000`                                          | Per-request timeout                                |
| `confidence_threshold`| `number` | `0.6`                                            | Minimum confidence to act on a route               |
| `file_candidates_max` | `integer`| `100`                                            | Max candidate files sent to Jev for `read_file`    |
| `on_error`            | `fun(err: string)` | notify                            | Error callback                                     |
| `on_uncertain`        | `fun(intent, confidence)` | notify                    | Low-confidence callback                            |
| `route_handlers`      | `table`  | builtin                                              | Per-intent overrides                               |