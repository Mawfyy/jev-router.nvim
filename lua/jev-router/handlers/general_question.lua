---@mod jev-router.handlers.general_question Answer a broad question with a chat
---model and show the reply in a floating window.

local config = require("jev-router.config")
local api = require("jev-router.api")

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

---Answer `prompt` with a chat model and show the reply in a floating window.
---@param prompt string
function M.run(prompt)
  local messages = {
    {
      role = "system",
      content = "You are a helpful assistant answering the user's question "
        .. "about their code or project. Be concise and accurate.",
    },
    {
      role = "user",
      content = prompt,
    },
  }

  api.chat(messages, function(text, err)
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
end

return M