---@mod jev-router.handlers.general_question Answer a broad question with a chat
---model and show the reply in a floating window.

local config = require("jev-router.config")
local api = require("jev-router.api")
local files = require("jev-router.files")

local M = {}

---Render the answer in a scratch floating window.
---@param question string
---@param answer string
function M.display(question, answer)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")

  local full = "# " .. question .. "\n\n" .. answer .. "\n"
  local lines = vim.split(full, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- Size the window to the content, capped so it stays on-screen.
  local width = math.max(40, math.min(100, vim.o.columns - 8))
  local height = math.max(4, math.min(#lines, vim.o.lines - 6))

  local opts = {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " jev-router answer ",
    title_pos = "center",
  }

  local win = vim.api.nvim_open_win(buf, false, opts)

  local close = vim.api.nvim_replace_termcodes("<Esc>q", true, false, true)
  vim.keymap.set("n", "q", close, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", ":close<CR>", { buffer = buf, nowait = true })

  vim.wo.wrap = true
end

---Answers `prompt` with a chat model (routed by `complexity`) after injecting
---bounded project context, then shows the reply in a floating window.
---@param prompt string
---@param complexity string|nil "quick" | "deep"
function M.run(prompt, complexity)
  local cfg = config.get()
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

    local messages = {
      { role = "system", content = table.concat(parts, "\n") },
      { role = "user", content = prompt },
    }

    api.chat(models, messages, function(text, err)
      if err then
        return
      end
      local answer = vim.trim(text or "")
      if answer == "" then
        config.get().on_error("empty_answer")
        return
      end
      M.display(prompt, answer)
    end)
  end)
end

return M