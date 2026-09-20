---@mod jev-router.handlers.edit_code Generate an edit for the active buffer with
---a chat model, show it in a diff, then apply on confirmation.

local config = require("jev-router.config")
local api = require("jev-router.api")

local M = {}

---Extract the content between code fences (the model's edited file). If the
---reply has no fence, it is used verbatim.
---@param text string
---@return string content
function M.extract_content(text)
  text = text or ""
  local opener = text:find("^```", 1)
  if opener == nil then
    return text
  end

  local lang_end = text:find("\n", opener)
  lang_end = lang_end or (opener + 2)

  local closer = text:find("```", lang_end, true)
  if closer == nil then
    return text:sub(lang_end + 1):gsub("\n$", "")
  end

  return text:sub(lang_end + 1, closer - 1):gsub("\n$", "")
end

---The active buffer's full text.
---@return string text
function M.buffer_text()
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return table.concat(lines, "\n")
end

---Preview the proposed change in a diff split and apply it on confirmation.
---@param buf number The target buffer.
---@param new_text string The proposed full-file content.
local function preview_and_apply(buf, new_text)
  local fname = vim.api.nvim_buf_get_name(buf)
  if fname == "" then
    fname = "buffer" .. buf
  end

  -- Write the proposed content to a temp file for the diff.
  local tmp = vim.fn.tempname()
  local f = io.open(tmp, "w")
  if f then
    f:write(new_text)
    f:close()
  else
    config.get().on_error("write_temp_failed")
    return
  end

  vim.cmd("tabnew")
  vim.cmd("vertical diffsplit " .. vim.fn.fnameescape(tmp))
  vim.cmd("setlocal buftype=nofile")

  -- Show a hint and await confirmation.
  local choice = vim.fn.confirm(
    "Apply this edit?",
    "&Apply\n&Discard",
    1
  )

  vim.cmd("tabclose")

  if choice == 1 then
    local new_lines = vim.split(new_text, "\n", { plain = true })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
    vim.notify("[jev-router] edit applied", vim.log.levels.INFO)
    os.remove(tmp)
  else
    os.remove(tmp)
  end
end

---Generate an edit for `prompt` against the current buffer, diff-preview it,
---and apply on confirmation.
---@param prompt string
function M.run(prompt)
  local buf = vim.api.nvim_get_current_buf()
  local text = M.buffer_text()

  if vim.trim(text) == "" then
    config.get().on_error("empty_buffer")
    return
  end

  local ftype = vim.bo[buf].filetype or ""
  local fname = vim.api.nvim_buf_get_name(buf) or ""

  local messages = {
    {
      role = "system",
      content = "You are a code-editing assistant. Given the user's request and the "
        .. "full current file content, output the complete updated file content. "
        .. "Wrap it in a ``` code fence. Preserve everything not relevant to the "
        .. "request. Do not explain; output only the file content.",
    },
    {
      role = "user",
      content = "File: " .. fname .. " (" .. ftype .. ")\n\nRequest: " .. prompt
        .. "\n\nCurrent content:\n```\n" .. text .. "\n```",
    },
  }

  api.chat(messages, function(reply, err)
    if err then
      return
    end
    local new_text = M.extract_content(reply or "")
    if vim.trim(new_text) == "" then
      config.get().on_error("empty_edit")
      return
    end
    preview_and_apply(buf, new_text)
  end)
end

return M