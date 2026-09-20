---@mod jev-router.api Async client for the OpenRouter Decisions API (Jev).

---The four intents the router can classify a prompt into.
---@alias jev-router.Intent "read_file" | "edit_code" | "run_command" | "general_question"

---@class jev-router.api.ParsedAnswer
---The highest-probability option selected by the model.
---@field choice jev-router.intent
---Confidence (0..1) derived from the probability distribution.
---@field confidence number
---Full probability map: intent name -> probability (0..1), summed to 1.
---@field probabilities table<string, number>
---The model that answered the request.
---@field model string
---Token usage reported by the API.
---@field usage table

local M = {}

---A stable reference to the config module so get() is always current.
local config = require("jev-router.config")

---Render a Lua value to a JSON string.
---Neovim ships vim.json (>= 0.6); keep a defensive fallback to vim.fn.json_encode.
---@param value table|string|number|boolean|nil
---@return string json
local function encode(value)
  if vim.json and vim.json.encode then
    return vim.json.encode(value)
  end
  local json = vim.fn.json_encode(value)
  if json ~= nil and json ~= "" then
    return json
  end
  error("no JSON encoder available")
end

---Build the Decisions API request body for a single Choice question.
---@param prompt string
---@return table payload
function M.build_payload(prompt)
  return {
    model = config.get().model,
    state = prompt,
    questions = {
      intent = {
        type = "choice",
        instructions = "What does the user want to do?",
        criteria = {
          read_file = "Understand or inspect the active buffer / file content.",
          edit_code = "Modify, refactor, or write code in the active buffer.",
          run_command = "Execute a terminal command such as running tests or a build.",
          general_question = "A broad question requiring no file context.",
        },
      },
    },
  }
end

---Parse a raw API response body into a ParsedAnswer.
---@param body string Raw response body.
---@return jev-router.api.ParsedAnswer|nil parsed
---@return string|nil err
function M.parse(body)
  if vim.json == nil or vim.json.decode == nil then
    return nil, "bad_json"
  end

  local ok, decoded = pcall(vim.json.decode, body)
  if not ok or type(decoded) ~= "table" then
    return nil, "bad_json"
  end

  -- OpenRouter errors carry { error = { code, message } }.
  if decoded.error and type(decoded.error) == "table" then
    local code = tostring(decoded.error.code or "unknown")
    local msg = tostring(decoded.error.message or "unknown error")
    return nil, "api_error:" .. code .. ":" .. msg
  end

  local answers = decoded.answers
  if type(answers) ~= "table" or type(answers.intent) ~= "table" then
    return nil, "bad_json"
  end

  local intent = answers.intent
  return {
    choice = intent.choice,
    confidence = tonumber(intent.confidence) or 0,
    probabilities = intent.probabilities or {},
    model = decoded.model,
    usage = decoded.usage or {},
  }
end

---Classify `prompt` via the Decisions API and invoke `callback`.
---
---Uses `vim.system` to run curl non-blocking so the UI never freezes. If curl
---is not available on the host, the failure is reported through `on_error`.
---@param prompt string
---@param callback fun(parsed: jev-router.api.ParsedAnswer|nil, err: string|nil)
function M.prompt(prompt, callback)
  vim.validate({
    prompt = { prompt, "string" },
    callback = { callback, "function" },
  })

  local cfg = config.get()

  if cfg.api_key == nil or cfg.api_key == "" then
local err = "no_api_key: set OPENROUTER_API_KEY or configure api_key"
    cfg.on_error(err)
    callback(nil, err)
    return
  end

  if vim.fn.executable("curl") == 0 then
    local err = "curl_missing: curl is required but not found on PATH"
    cfg.on_error(err)
    callback(nil, err)
    return
  end

  local body = encode(M.build_payload(prompt))

  local args = {
    "curl",
    "--silent",
    "--show-error",
    "--max-time", tostring(math.floor(cfg.timeout_ms / 1000)),
    "--request", "POST",
    cfg.endpoint,
    "--header", "Authorization: Bearer " .. cfg.api_key,
    "--header", "Content-Type: application/json",
    "--data-binary", body,
  }

  if cfg.http_referer ~= nil and cfg.http_referer ~= "" then
    table.insert(args, "--header")
    table.insert(args, "HTTP-Referer: " .. cfg.http_referer)
  end
  if cfg.app_title ~= nil and cfg.app_title ~= "" then
    table.insert(args, "--header")
    table.insert(args, "X-Title: " .. cfg.app_title)
  end

  ---@param obj vim.SystemCompleted
  local function on_exit(obj)
    if obj.code ~= 0 then
      local err = "request_failed: curl exit " .. tostring(obj.code)
      if obj.stderr ~= nil and obj.stderr ~= "" then
        err = err .. " (" .. vim.trim(obj.stderr) .. ")"
      end
      cfg.on_error(err)
      callback(nil, err)
      return
    end

    local parsed, perr = M.parse(obj.stdout or "")
    if perr then
      cfg.on_error(perr)
      callback(nil, perr)
      return
    end

    callback(parsed)
  end

  vim.system(args, {}, on_exit)
end

return M