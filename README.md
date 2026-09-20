# jev-router.nvim

An intent router for Neovim that classifies AI commands with
[Jev](https://docs.typesafe.ai) (TypeSafe's System One model) via the
[OpenRouter Decisions API](https://openrouter.ai/docs/api/api-reference/alphadecisions/submit-a-decisions-questions-and-answers-request),
then routes execution to the matching handler.

The plugin sends the user's prompt as `state`, asks Jev a single `choice`
question (`intent`), and maps the result to one of four routes:

| Intent            | Meaning                                              |
| ----------------- | ---------------------------------------------------- |
| `read_file`       | Understand / inspect the active buffer               |
| `edit_code`       | Modify / write code in the active buffer             |
| `run_command`     | Run a terminal command (tests, build, ...)           |
| `general_question`| A broad question needing no file context             |

## Requirements

- Neovim **0.10+** (`vim.system`), and `curl` on `$PATH`.

## Install (lazy.nvim)

```lua
{
  "yourname/jev-router.nvim",
  opts = {
    -- api_key = "sk-or-...", -- or set OPENROUTER_API_KEY in your environment
    confidence_threshold = 0.6,
  },
}
```

No external Lua dependencies are required.

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
:JevAsk implement a fibonacci function
:JevAsk run the test suite
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

The `general_question` intent is implemented natively: it sends the prompt to a
chat model and shows the answer in a floating window (press `q` or `<Esc>` to
close).

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

## Configuration

| Option                | Type     | Default                                          | Description                                        |
| --------------------- | -------- | ------------------------------------------------ | -------------------------------------------------- |
| `api_key`             | `string` | `$OPENROUTER_API_KEY`                            | OpenRouter API key                                 |
| `endpoint`            | `string` | `https://openrouter.ai/api/alpha/decisions`      | Decisions endpoint                                 |
| `model`               | `string` | `typesafe/jev-1.13`                             | Model alias                                        |
| `chat_model`          | `string` | `openai/gpt-4o-mini`                             | Chat model for command/answer generation           |
| `chat_endpoint`       | `string` | `https://openrouter.ai/api/v1/chat/completions` | Chat-completions endpoint                          |
| `timeout_ms`          | `integer`| `30000`                                          | Per-request timeout                                |
| `confidence_threshold`| `number` | `0.6`                                            | Minimum confidence to act on a route               |
| `file_candidates_max` | `integer`| `100`                                            | Max candidate files sent to Jev for `read_file`    |
| `on_error`            | `fun(err: string)` | notify                            | Error callback                                     |
| `on_uncertain`        | `fun(intent, confidence)` | notify                    | Low-confidence callback                            |
| `route_handlers`      | `table`  | stubs                                            | Per-intent overrides                               |