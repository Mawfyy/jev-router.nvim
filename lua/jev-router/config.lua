---@mod jev-router.config Configuration for jev-router.nvim.

---@class jev-router.config.Options
---OpenRouter API key. When unset, falls back to OPENROUTER_API_KEY.
---@field api_key? string
---Decisions endpoint.
---@field endpoint? string
---Model alias sent in the `model` request field.
---@field model? string
---Per-request timeout in milliseconds.
---@field timeout_ms? integer
---Minimum Choice `confidence` (0..1) required to act on a route. Below this the
---intent is treated as uncertain and handed to `on_uncertain`.
---@field confidence_threshold? number
---HTTP referer header (OpenRouter attribution). Optional.
---@field http_referer? string
---App title header (OpenRouter attribution). Optional.
---@field app_title? string
---Called with an error string when a check or network call fails.
---@field on_error? fun(err: string)
---Called with the intent string when confidence is below `confidence_threshold`.
---@field on_uncertain? fun(intent: string, confidence: number)
---Optional per-intent route handlers, keyed by intent name. Overrides the
---built-in stub handlers. Keys: read_file, edit_code, run_command, general_question.
---@field route_handlers? table<string, fun(prompt: string)>

---@class jev-router.config.Config
---@field api_key string
---@field endpoint string
---@field model string
---@field timeout_ms integer
---@field confidence_threshold number
---@field http_referer string
---@field app_title string
---@field on_error fun(err: string)
---@field on_uncertain fun(intent: string, confidence: number)
---@field route_handlers table<string, fun(prompt: string)>

local M = {}

---@type jev-router.config.Options
M.defaults = {
  endpoint = "https://openrouter.ai/api/alpha/decisions",
  model = "typesafe/jev-1.13",
  timeout_ms = 30000,
  confidence_threshold = 0.6,
  on_error = function(err) vim.notify("[jev-router] " .. err, vim.log.levels.ERROR) end,
  on_uncertain = function(intent, confidence)
    vim.notify(
      string.format(
        "[jev-router] intent %q too uncertain (confidence %.2f); no route executed",
        intent,
        confidence
      ),
      vim.log.levels.WARN
    )
  end,
}

---@type jev-router.config.Options
M._user_opts = {}

---@class jev-router.config.Config
local config = setmetatable({}, { __index = M.defaults })

---Merge and store user overrides, then resolve derived values.
---@param opts? jev-router.config.Options
function M.setup(opts)
  M._user_opts = vim.tbl_deep_extend("force", M._user_opts or {}, opts or {})

  config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), M._user_opts or {})

  -- Resolve the API key: explicit option wins, then the env var.
  if config.api_key == nil or config.api_key == "" then
    config.api_key = vim.env.OPENROUTER_API_KEY or ""
  end

  return config
end

---Return the merged config object.
---@return jev-router.config.Config
function M.get()
  return config
end

---Resolve an API key. Convenience accessor for callers that need to check it.
---@return string api_key
function M.api_key()
  return M.get().api_key
end

return M