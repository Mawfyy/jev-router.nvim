---@mod jev-router.handlers.run_command Generate, confirm, and run a terminal
---command for a prompt.

local config = require("jev-router.config")
local api = require("jev-router.api")
local conversation = require("jev-router.conversation")

local M = {}

---Strip markdown code fences and leading/trailing whitespace from a model
---reply, keeping at most one candidate command when wrapped in a block.
---@param text string
---@return string cleaned
function M.clean(text)
  text = vim.trim(text)

  -- Fenced block: take the first fence's content.
  local fenced = text:match("^```[a-zA-Z]*%s*\n(.-)\n?```%s*$")
  if fenced then
    return vim.trim(fenced)
  end

  -- Strip a leading shell prompt and backticks.
  text = text:gsub("^%s*`", "")
  text = text:gsub("`%s*$", "")
  text = text:gsub("^[%%%$#>]%s*", "")
  return vim.trim(text)
end

---The command given by the user (after the leading intent words).
---@param prompt string
---@return string
local function strip_intent(prompt)
  local p = vim.trim(prompt)
  p = p:gsub("^[Rr]un%s+" , "")
  p = p:gsub("^[Ee]xecute%s+" , "")
  return vim.trim(p)
end

---Run a command in a new terminal split, focused on the terminal.
---@param cmd string
function M.execute(cmd)
  cmd = vim.trim(cmd)
  if cmd == "" then
    config.get().on_error("empty_command")
    return
  end

  -- lower-right terminal split, as in the README example
  vim.cmd("botright 12split | terminal " .. cmd)
end

---Preview the generated command and ask for confirmation before running.
---@param cmd string
local function confirm_and_run(cmd)
  vim.ui.input({
    prompt = "Run command (edit to adjust, Enter to run, Esc to cancel): ",
    default = cmd,
  }, function(answer)
    if answer == nil then
      return
    end
    if vim.trim(answer) == "" then
      config.get().on_error("empty_command")
      return
    end
    M.execute(answer)
    conversation.append_assistant(vim.api.nvim_get_current_buf(), "Ran: " .. answer)
  end)
end

---Generate a command for `prompt` and run it, asking for confirmation first.
---@param prompt string
function M.run(prompt)
  local target = strip_intent(prompt)

  local messages = {
    {
      role = "system",
      content = "You output a single shell command to satisfy the user's request. "
        .. "Reply with only the command, optionally inside a ``` fence. "
        .. "Do not explain. Prefer common, safe, project-appropriate commands "
        .. "(e.g. test/build/lint) based on the working directory.",
    },
    {
      role = "user",
      content = "Working directory: " .. vim.fn.getcwd() .. "\nRequest: " .. target,
    },
  }

  api.chat(config.get().chat_model, messages, function(text, err)
    if err then
      return
    end
    local cmd = M.clean(text or "")
    if cmd == "" then
      config.get().on_error("empty_command")
      return
    end
    confirm_and_run(cmd)
  end)
end

return M