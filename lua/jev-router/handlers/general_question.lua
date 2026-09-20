---@mod jev-router.handlers.general_question Answer a broad question with a chat
---model and show the reply in a floating window (streamed when enabled).

local config = require("jev-router.config")
local api = require("jev-router.api")
local files = require("jev-router.files")
local conversation = require("jev-router.conversation")

local M = {}

---@class jev-router.handlers.general_question.Window
---@field buf number
---@field win number
---@field question string

---Open a floating window and return its handle.
---@param question string
---@return jev-router.handlers.general_question.Window
function M.open_window(question)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# " .. question, "", "…" })

  local width = math.max(40, math.min(100, vim.o.columns - 8))
  local height = math.max(4, math.min(12, vim.o.lines - 6))

  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " jev-router answer ",
    title_pos = "center",
  })

  vim.wo.wrap = true

  local close = vim.api.nvim_replace_termcodes("<Esc>q", true, false, true)
  vim.keymap.set("n", "q", close, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", ":close<CR>", { buffer = buf, nowait = true })

  return { buf = buf, win = win, question = question }
end

---Replace the window content with the current answer, growing the window height
---up to an on-screen cap.
---@param handle jev-router.handlers.general_question.Window
---@param answer string
local function render(handle, answer)
  local lines = vim.split("# " .. handle.question .. "\n\n" .. answer, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(handle.buf, 0, -1, false, lines)

  local cap = vim.o.lines - 6
  local height = math.max(4, math.min(#lines, cap))
  vim.api.nvim_win_set_height(handle.win, height)
end

---Append a streamed delta to the open window.
---@param handle jev-router.handlers.general_question.Window
---@param answer string The accumulated answer so far.
---@param delta string
local function append(handle, answer, delta)
  render(handle, answer .. delta)
end

---Answer `prompt` with a chat model (routed by `complexity`) after injecting
---bounded project context, then show the reply in a floating window.
---@param prompt string
---@param complexity string|nil "quick" | "deep"
function M.run(prompt, complexity)
  local cfg = config.get()
  local bufnr = vim.api.nvim_get_current_buf()
  local tier = complexity == "deep" and "deep" or "quick"
  local models = (cfg.chat_models and cfg.chat_models[tier]) or cfg.chat_model
  if type(models) == "string" then
    models = { models }
  end
  if models == nil or #models == 0 then
    models = { cfg.chat_model }
  end

  files.gather_context(function(ctx)
    local parts = {
      "You are a helpful assistant answering the user's question about their "
        .. "code or project. Be concise and accurate.",
    }

    if ctx.tree ~= "" then
      parts[#parts + 1] = "\nProject files:\n" .. ctx.tree
    end
    if next(ctx.files) ~= nil then
      local file_parts = {}
      for path, content in pairs(ctx.files) do
        file_parts[#file_parts + 1] = "--- " .. path .. " ---\n" .. content
      end
      parts[#parts + 1] = "\nKey files:\n" .. table.concat(file_parts, "\n\n")
    end
    if ctx.buffer ~= "" then
      parts[#parts + 1] = "\nActive buffer:\n" .. ctx.buffer
    end

    local messages = { { role = "system", content = table.concat(parts, "\n") } }
    local history = conversation.messages(bufnr)
    if #history > 0 then
      for _, m in ipairs(history) do
        messages[#messages + 1] = m
      end
    else
      messages[#messages + 1] = { role = "user", content = prompt }
    end

    if cfg.stream then
      local handle = M.open_window(prompt)
      local answer = ""

      api.chat_stream(models, messages, function(delta)
        append(handle, answer, delta)
        answer = answer .. delta
      end, function(text, err)
        if err and answer == "" then
          vim.api.nvim_win_close(handle.win, true)
          return
        end
        answer = vim.trim(text ~= nil and text or answer)
        if answer ~= "" then
          render(handle, answer)
          conversation.append_assistant(bufnr, answer)
        end
      end)
    else
      api.chat(models, messages, function(text, err)
        if err then
          return
        end
        local answer = vim.trim(text or "")
        if answer == "" then
          config.get().on_error("empty_answer")
          return
        end
        render(M.open_window(prompt), answer)
        conversation.append_assistant(bufnr, answer)
      end)
    end
  end)
end

return M