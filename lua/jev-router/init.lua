---@mod jev-router Intent router for AI commands, powered by Jev (TypeSafe)
---via the OpenRouter Decisions API.

local config = require("jev-router.config")
local api = require("jev-router.api")
local conversation = require("jev-router.conversation")
local read_file_handler = require("jev-router.handlers.read_file")
local run_command_handler = require("jev-router.handlers.run_command")
local general_question_handler = require("jev-router.handlers.general_question")
local edit_code_handler = require("jev-router.handlers.edit_code")

local M = {}

---@param prompt string
local function route_read_file(prompt)
  read_file_handler.run(prompt)
end

---@param prompt string
local function route_edit_code(prompt)
  edit_code_handler.run(prompt)
end

---@param prompt string
local function route_run_command(prompt)
  run_command_handler.run(prompt)
end

---@param prompt string
---@param answer jev-router.api.ParsedAnswer
local function route_general_question(prompt, answer)
  general_question_handler.run(prompt, answer and answer.complexity)
end

---@type table<jev-router.Intent, fun(prompt: string)>
local builtin_routes = {
  read_file = route_read_file,
  edit_code = route_edit_code,
  run_command = route_run_command,
  general_question = route_general_question,
}

---Apply user route_handlers over the built-in stubs.
---@return table<string, fun(prompt: string)>
local function resolve_routes()
  local routes = vim.tbl_extend("force", {}, builtin_routes)
  local overrides = config.get().route_handlers
  if overrides then
    for intent, fn in pairs(overrides) do
      routes[intent] = fn
    end
  end
  return routes
end

---Execute the routing decision for a classified answer.
---Gates on confidence, then dispatches to the matching handler.
---@param answer jev-router.api.ParsedAnswer
---@param prompt string
local function run_router(answer, prompt)
  local cfg = config.get()
  local intent = answer.choice

  if (answer.confidence or 0) < cfg.confidence_threshold then
    cfg.on_uncertain(intent, answer.confidence)
    return
  end

  local routes = resolve_routes()
  local handler = routes[intent]

  if handler == nil then
    cfg.on_error("unknown_intent: " .. tostring(intent))
    return
  end

  handler(prompt, answer)
end

---Handle the result of a classification request.
---@param parsed jev-router.api.ParsedAnswer|nil
---@param err string|nil
---@param prompt string
local function on_classified(parsed, err, prompt)
  if err then
    return
  end
  run_router(parsed, prompt)
end

---The core entry: classify and route a single prompt string.
---@param prompt string
function M.ask(prompt)
  if vim.trim(prompt) == "" then
    config.get().on_error("empty_prompt")
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()

  -- Prior turns hint the router so follow-ups (e.g. "now refactor it") route
  -- correctly. Capture before recording the current turn.
  local summary = conversation.summary(bufnr)

  conversation.append_user(bufnr, prompt)

  api.prompt(prompt, function(parsed, err)
    on_classified(parsed, err, prompt)
  end, summary)
end

---Ask about the current visual/line selection, or the whole buffer when there
---is no selection. Falls back to the provided prompt if both are empty.
---@param prompt string An optional prompt merged before the selection when present.
function M.ask_buffer(prompt)
  prompt = prompt or ""

  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local text = table.concat(lines, "\n")

  if prompt ~= "" then
    text = prompt .. "\n\n" .. text
  end

  if vim.trim(text) == "" then
    config.get().on_error("empty_buffer")
    return
  end

  M.ask(text)
end

---Set up the plugin and register user commands.
---@param opts? jev-router.config.Options
function M.setup(opts)
  config.setup(opts)

  vim.api.nvim_create_user_command("JevAsk", function(ctx)
    M.ask(ctx.args)
  end, {
    nargs = "+",
    desc = "Classify an AI command with Jev and route it",
  })

  vim.api.nvim_create_user_command("JevAskBuffer", function(ctx)
    M.ask_buffer(ctx.args)
  end, {
    nargs = "?",
    desc = "Classify the current buffer (optionally with a leading prompt)",
  })

  vim.api.nvim_create_user_command("JevClear", function()
    conversation.clear(vim.api.nvim_get_current_buf())
    vim.notify("[jev-router] conversation cleared", vim.log.levels.INFO)
  end, {
    nargs = 0,
    desc = "Clear the current buffer's Jev conversation history",
  })
end

return M