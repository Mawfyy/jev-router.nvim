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

Routes currently notify via `vim.notify` as placeholders. Wire up real behavior
by overriding `route_handlers` in `setup`:

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
| `timeout_ms`          | `integer`| `30000`                                          | Per-request timeout                                |
| `confidence_threshold`| `number` | `0.6`                                            | Minimum confidence to act on a route               |
| `on_error`            | `fun(err: string)` | notify                            | Error callback                                     |
| `on_uncertain`        | `fun(intent, confidence)` | notify                    | Low-confidence callback                            |
| `route_handlers`      | `table`  | stubs                                            | Per-intent overrides                               |