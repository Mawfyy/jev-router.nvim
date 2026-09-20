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

---Build a Decisions API request body for a single Choice question.
---@param prompt string The `state` passed to the model.
---@param question_id string The question key (e.g. "intent", "file").
---@param instructions string What the model should decide.
---@param criteria table<string, string> Option id -> description.
---@return table payload
function M.build_choice_payload(prompt, question_id, instructions, criteria)
  return {
    model = config.get().model,
    state = prompt,
    questions = {
      [question_id] = {
        type = "choice",
        instructions = instructions,
        criteria = criteria,
      },
    },
  }
end

---Build the intent routing request body. Also asks a parallel `complexity`
---question (quick vs deep) consumed by chat-backed handlers like
---`general_question`; it runs in the same request for zero extra latency.
---@param prompt string
---@param history string|nil Optional recent-turn summary for follow-up routing.
---@return table payload
function M.build_payload(prompt, history)
  local state = prompt
  if history ~= nil and history ~= "" then
    state = "Conversation so far:\n" .. history .. "\n\nCurrent request: " .. prompt
  end

  return {
    model = config.get().model,
    state = state,
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
      complexity = {
        type = "choice",
        instructions = "How much reasoning does answering this request require?",
        criteria = {
          quick = "A simple, factual, or well-known answer needing little reasoning.",
          deep = "Open-ended, architectural, or multi-step reasoning about the project.",
        },
      },
    },
  }
end

---Parse the answer for a single question from a raw Decisions API response.
---@param body string Raw response body.
---@param question_id string The question key to extract (default "intent").
---@return jev-router.api.ParsedAnswer|nil parsed
---@return string|nil err
function M.parse_question(body, question_id)
  question_id = question_id or "intent"

  local answers, err = M.parse_answers(body)
  if err then
    return nil, err
  end

  local answer = answers[question_id]
  if answer == nil then
    return nil, "bad_json"
  end

  return answer
end

---Parse every answer from a raw Decisions API response into a map of
---question id -> ParsedAnswer.
---@param body string Raw response body.
---@return table<string, jev-router.api.ParsedAnswer>|nil answers
---@return string|nil err
function M.parse_answers(body)
  if vim.json == nil or vim.json.decode == nil then
    return nil, "bad_json"
  end

  local ok, decoded = pcall(vim.json.decode, body)
  if not ok or type(decoded) ~= "table" then
    return nil, "bad_json"
  end

  if decoded.error and type(decoded.error) == "table" then
    local code = tostring(decoded.error.code or "unknown")
    local msg = tostring(decoded.error.message or "unknown error")
    return nil, "api_error:" .. code .. ":" .. msg
  end

  local answers = decoded.answers
  if type(answers) ~= "table" then
    return nil, "bad_json"
  end

  local out = {}
  for qid, answer in pairs(answers) do
    if type(answer) == "table" then
      out[qid] = {
        choice = answer.choice,
        confidence = tonumber(answer.confidence) or 0,
        probabilities = answer.probabilities or {},
        model = decoded.model,
        usage = decoded.usage or {},
      }
    end
  end

  return out
end

---Parse the `intent` answer from a raw Decisions API response.
---@param body string Raw response body.
---@return jev-router.api.ParsedAnswer|nil parsed
---@return string|nil err
function M.parse(body)
  return M.parse_question(body, "intent")
end

---Send a Decisions API request body and invoke `callback` with the parsed
---answer for `question_id`.
---
---Uses `vim.system` to run curl non-blocking so the UI never freezes. If curl
---is not available on the host, the failure is reported through `on_error`.
---@param payload table Encoded request body (contains `state`, `questions`).
---@param question_id string The question key to parse from the response.
---@param callback fun(parsed: jev-router.api.ParsedAnswer|nil, err: string|nil)
function M.decide(payload, question_id, callback)
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

  local body = encode(payload)

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
      vim.schedule(function() callback(nil, err) end)
      return
    end

    local answers, perr = M.parse_answers(obj.stdout or "")
    if perr then
      cfg.on_error(perr)
      vim.schedule(function() callback(nil, perr) end)
      return
    end

    local parsed = answers[question_id]
    if parsed == nil then
      local err = "bad_json"
      cfg.on_error(err)
      vim.schedule(function() callback(nil, err) end)
      return
    end

    -- Attach sibling answers (e.g. the parallel `complexity` question) so
    -- callers can consume them without an extra request.
    parsed.answers = answers
    if answers.complexity then
      parsed.complexity = answers.complexity.choice
    end

    vim.schedule(function() callback(parsed) end)
  end

  vim.system(args, {}, on_exit)
end

---Classify `prompt` via the Decisions API and invoke `callback`.
---@param prompt string
---@param callback fun(parsed: jev-router.api.ParsedAnswer|nil, err: string|nil)
---@param history string|nil Optional recent-turn summary for follow-up routing.
function M.prompt(prompt, callback, history)
  vim.validate({
    prompt = { prompt, "string" },
    callback = { callback, "function" },
  })
  M.decide(M.build_payload(prompt, history), "intent", callback)
end

---Ask Jev which candidate file the user is referring to, then invoke `callback`.
---Each candidate path becomes a Choice option; the winner's id is the chosen path.
---@param candidates string[] Candidate file paths (absolute).
---@param prompt string The original user prompt (question `state`).
---@param callback fun(parsed: jev-router.api.ParsedAnswer|nil, err: string|nil)
function M.select_file(candidates, prompt, callback)
  vim.validate({
    candidates = { candidates, "table" },
    prompt = { prompt, "string" },
    callback = { callback, "function" },
  })

  local n = #candidates
  if n == 0 then
    callback(nil, "no_candidates")
    return
  end

  local criteria = {}
  for _, path in ipairs(candidates) do
    criteria[path] = path
  end

  local payload = M.build_choice_payload(
    prompt,
    "file",
    "Which file is the user referring to?",
    criteria
  )

  M.decide(payload, "file", callback)
end

---Send a single chat-completions request for `model`.
---@param model string
---@param messages table[]
---@param callback fun(text: string|nil, err: string|nil)
---@param opts? table Extra request fields (e.g. `response_format`), merged into the body.
local function chat_once(model, messages, callback, opts)
  local cfg = config.get()

  local body = vim.tbl_extend("force", {
    model = model,
    messages = messages,
  }, opts or {})

  local args = {
    "curl",
    "--silent",
    "--show-error",
    "--max-time", tostring(math.floor(cfg.timeout_ms / 1000)),
    "--request", "POST",
    cfg.chat_endpoint,
    "--header", "Authorization: Bearer " .. cfg.api_key,
    "--header", "Content-Type: application/json",
    "--data-binary", encode(body),
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
      vim.schedule(function() callback(nil, err) end)
      return
    end

    local ok, decoded = pcall(vim.json.decode, obj.stdout or "")
    if not ok or type(decoded) ~= "table" then
      local err = "bad_json"
      vim.schedule(function() callback(nil, err) end)
      return
    end

    if decoded.error and type(decoded.error) == "table" then
      local code = tostring(decoded.error.code or "unknown")
      local msg = tostring(decoded.error.message or "unknown error")
      local err = "api_error:" .. code .. ":" .. msg
      vim.schedule(function() callback(nil, err) end)
      return
    end

    local choice = decoded.choices and decoded.choices[1]
    local content = choice and choice.message and choice.message.content
    if content == nil or content == "" then
      local err = "empty_completion"
      vim.schedule(function() callback(nil, err) end)
      return
    end

    vim.schedule(function() callback(content) end)
  end

  vim.system(args, {}, on_exit)
end

---Whether an error from `chat_once` is worth retrying on the next model.
---Auth (401), bad requests (400), and missing config/curl are fatal.
---@param err string
---@return boolean retryable
local function retryable(err)
  if err == nil then
    return false
  end
  if err:find("no_api_key", 1, true) then return false end
  if err:find("curl_missing", 1, true) then return false end
  if err:find("api_error:401", 1, true) then return false end
  if err:find("api_error:400", 1, true) then return false end
  return true
end

---Call the built-in OpenRouter chat-completions client and invoke `callback`
---with the assistant's text reply. `models` is a single model id or an ordered
---list of ids; on a retryable failure (rate limit, disabled model, network) the
---next model in the list is tried.
---
---@param models string|string[] Model id(s) to try, in order.
---@param messages table[] An array of `{ role = "system"|"user"|"assistant", content = string }`.
---@param callback fun(text: string|nil, err: string|nil)
---@param opts? table Extra request fields (e.g. `response_format`).
function M.openrouter_chat(models, messages, callback, opts)
  vim.validate({
    messages = { messages, "table" },
    callback = { callback, "function" },
  })

  local cfg = config.get()

  local list
  if type(models) == "string" then
    list = { models }
  elseif type(models) == "table" and #models > 0 then
    list = models
  else
    list = { cfg.chat_model }
  end

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

  local i = 0
  local function try_next(last_err)
    i = i + 1
    local model = list[i]
    if model == nil then
      cfg.on_error(last_err or "all_models_failed")
      callback(nil, last_err)
      return
    end

    chat_once(model, messages, function(content, err)
      if err ~= nil and retryable(err) then
        try_next(err)
      else
        callback(content, err)
      end
    end, opts)
  end

  try_next()
end

---Invoke the configured chat backend (or the built-in OpenRouter client) with
---the assistant's text reply. Provides the `chat_backend` extensibility seam.
---
---@param models string|string[] Model id(s) to try, in order.
---@param messages table[] An array of `{ role = "system"|"user"|"assistant", content = string }`.
---@param callback fun(text: string|nil, err: string|nil)
---@param opts? table Extra request fields (e.g. `response_format`).
function M.chat(models, messages, callback, opts)
  local backend = config.get().chat_backend
  if backend ~= nil then
    return backend(models, messages, callback, opts)
  end
  return M.openrouter_chat(models, messages, callback, opts)
end

---Parse an SSE stream from OpenRouter's streaming chat-completions endpoint.
---Maintains a line buffer across arbitrary chunk boundaries and invokes
---`on_chunk` per text delta and `on_done` with the final text/error.
---
---@param on_chunk fun(delta: string)
---@return table sse A state object with `feed(data)` and `finish()`.
local function sse_state(on_chunk)
  local state = {
    buf = "",
    text = "",
    done = false,
  }

  ---@param record string A full SSE record (without the trailing blank line).
  local function handle_record(record)
    for data in record:gmatch("data:[^\r\n]*") do
      local payload = data:sub(6):gsub("^%s+", "")
      if payload == "[DONE]" then
        state.done = true
      else
        local ok, decoded = pcall(vim.json.decode, payload)
        if ok and type(decoded) == "table" then
          local choice = decoded.choices and decoded.choices[1]
          local delta = choice and choice.delta and choice.delta.content
          if delta ~= nil and delta ~= "" then
            state.text = state.text .. delta
            on_chunk(delta)
          end
          if decoded.error and type(decoded.error) == "table" then
            state.err = "api_error:" .. tostring(decoded.error.code or "unknown")
          end
        end
      end
    end
  end

  ---@param data string A raw chunk from the stdout stream.
  function state.feed(data)
    if data == nil then
      return
    end
    state.buf = state.buf .. data
    local sep
    while true do
      sep = state.buf:find("\n\n", 1, true)
      if not sep then
        break
      end
      local record = state.buf:sub(1, sep - 1)
      state.buf = state.buf:sub(sep + 2)
      handle_record(record)
    end
  end

  function state.finish()
    if state.buf ~= "" then
      handle_record(state.buf)
      state.buf = ""
    end
  end

  return state
end

---Run one streaming request for `model`.
---@param model string
---@param messages table[]
---@param on_chunk fun(delta: string)
---@param on_done fun(text: string|nil, err: string|nil)
local function stream_once(model, messages, on_chunk, on_done)
  local cfg = config.get()

  local body = encode({
    model = model,
    messages = messages,
    stream = true,
  })

  local args = {
    "curl",
    "--silent",
    "--show-error",
    "--no-buffer",
    "--max-time", tostring(math.floor(cfg.timeout_ms / 1000)),
    "--request", "POST",
    cfg.chat_endpoint,
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

  local sse = sse_state(function(delta)
    vim.schedule(function() on_chunk(delta) end)
  end)

  -- Non-JSON error payload (curl prints an error body to stderr but exits 0 in
  -- some cases); capture stderr for diagnostics.
  local stderr_buf = ""

  ---@param obj vim.SystemCompleted
  local function on_exit(obj)
    if obj.code ~= 0 then
      local err = "request_failed: curl exit " .. tostring(obj.code)
      if stderr_buf ~= "" then
        err = err .. " (" .. vim.trim(stderr_buf) .. ")"
      end
      cfg.on_error(err)
      vim.schedule(function() on_done(nil, err) end)
      return
    end

    sse.finish()
    if sse.err ~= nil then
      vim.schedule(function() on_done(nil, sse.err) end)
    else
      vim.schedule(function() on_done(sse.text, nil) end)
    end
  end

  vim.system(args, {
    text = true,
    stdout = function(_, data)
      sse.feed(data)
    end,
    stderr = function(_, data)
      if data ~= nil then
        stderr_buf = stderr_buf .. data
      end
    end,
  }, on_exit)
end

---Stream a chat-completions request through the built-in OpenRouter client.
---`on_chunk` receives each text delta; `on_done(text, err)` fires once at end.
---
---@param models string|string[] Model id(s) to try, in order.
---@param messages table[]
---@param on_chunk fun(delta: string)
---@param on_done fun(text: string|nil, err: string|nil)
function M.openrouter_chat_stream(models, messages, on_chunk, on_done)
  local cfg = config.get()

  local list
  if type(models) == "string" then
    list = { models }
  elseif type(models) == "table" and #models > 0 then
    list = models
  else
    list = { cfg.chat_model }
  end

  if cfg.api_key == nil or cfg.api_key == "" then
    local err = "no_api_key: set OPENROUTER_API_KEY or configure api_key"
    cfg.on_error(err)
    on_done(nil, err)
    return
  end

  if vim.fn.executable("curl") == 0 then
    local err = "curl_missing: curl is required but not found on PATH"
    cfg.on_error(err)
    on_done(nil, err)
    return
  end

  local i = 0
  local function try_next(last_err)
    i = i + 1
    local model = list[i]
    if model == nil then
      cfg.on_error(last_err or "all_models_failed")
      on_done(nil, last_err)
      return
    end
    stream_once(model, messages, on_chunk, function(text, err)
      if err ~= nil and retryable(err) then
        try_next(err)
      else
        on_done(text, err)
      end
    end)
  end

  try_next()
end

---Stream a chat response through the configured backend (or built-in), yielding
---text deltas via `on_chunk` and finishing via `on_done(text, err)`.
---
---@param models string|string[] Model id(s) to try, in order.
---@param messages table[]
---@param on_chunk fun(delta: string)
---@param on_done fun(text: string|nil, err: string|nil)
function M.chat_stream(models, messages, on_chunk, on_done)
  local backend = config.get().chat_stream_backend
  if backend ~= nil then
    return backend(models, messages, on_chunk, on_done)
  end
  return M.openrouter_chat_stream(models, messages, on_chunk, on_done)
end

return M