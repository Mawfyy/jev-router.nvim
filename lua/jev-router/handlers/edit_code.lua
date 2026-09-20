---@mod jev-router.handlers.edit_code Generate a precise edit for the active
---buffer with a chat model (structured find/replace JSON), show a diff preview,
---then apply on confirmation. Falls back to a full-file rewrite when the model
---does not return structured edits.

local config = require("jev-router.config")
local api = require("jev-router.api")
local conversation = require("jev-router.conversation")

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
    return (text:sub(lang_end + 1):gsub("\n$", ""))
  end

  return (text:sub(lang_end + 1, closer - 1):gsub("\n$", ""))
end

---The active buffer's full text.
---@return string text
function M.buffer_text()
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return table.concat(lines, "\n")
end

---Parse a JSON `{ "edits": [ { "find", "replace" } ] }` reply. Returns nil when
---the reply is not a valid edits object.
---@param reply string
---@return table|nil edits
function M.parse_edits(reply)
  local inner = vim.trim(reply or "")
  local ok, decoded = pcall(vim.json.decode, inner)
  if not (ok and type(decoded) == "table" and type(decoded.edits) == "table") then
    -- The model may wrap the JSON in a fence.
    ok, decoded = pcall(vim.json.decode, M.extract_content(inner))
  end
  if not (ok and type(decoded) == "table" and type(decoded.edits) == "table") then
    return nil
  end
  if #decoded.edits == 0 then
    return nil
  end
  return decoded.edits
end

---Apply a list of `{ find, replace }` edits to the active buffer's text. Each
---`find` must match exactly once (literal) over the full buffer; otherwise nil
---is returned (callers fall back to a full-file rewrite).
---@param buf number
---@param edits table[]
---@return string|nil result
function M.apply_edits(buf, edits)
  local text = M.buffer_text()

  for _, e in ipairs(edits) do
    local find = e.find or e.search
    local replace = e.replace or ""
    if find == nil or find == "" then
      return nil
    end

    local first = text:find(find, 1, true)
    if first == nil then
      return nil
    end
    local second = text:find(find, first + #find, true)
    if second ~= nil then
      return nil
    end

    text = text:sub(1, first - 1) .. replace .. text:sub(first + #find)
  end

  return text
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

  local choice = vim.fn.confirm("Apply this edit?", "&Apply\n&Discard", 1)

  vim.cmd("tabclose")

  if choice == 1 then
    local new_lines = vim.split(new_text, "\n", { plain = true })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
    vim.notify("[jev-router] edit applied", vim.log.levels.INFO)
  end

  os.remove(tmp)
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
        .. "current file content, produce a minimal set of edits as JSON: "
        .. '{"edits":[{"find":"<exact text to replace>","replace":"<replacement>"}]}. '
        .. 'Each "find" must be an exact, literal substring that occurs exactly '
        .. 'once in the current content. Use the shortest "find" that uniquely '
        .. 'identifies the location. Output only the JSON object.',
    },
    {
      role = "user",
      content = "File: " .. fname .. " (" .. ftype .. ")\n\nRequest: " .. prompt
        .. "\n\nCurrent content:\n```\n" .. text .. "\n```",
    },
  }

  api.chat(config.get().chat_model, messages, function(reply, err)
    if err then
      return
    end

    local edits = M.parse_edits(reply or "")
    if edits ~= nil then
      local result = M.apply_edits(buf, edits)
      if result ~= nil and vim.trim(result) ~= "" then
        preview_and_apply(buf, result)
        conversation.append_assistant(buf, "Edited the buffer.")
        return
      end
    end

    -- Fallback: full-file rewrite from a code fence.
    local new_text = M.extract_content(reply or "")
    if vim.trim(new_text) == "" then
      config.get().on_error("empty_edit")
      return
    end
    preview_and_apply(buf, new_text)
    conversation.append_assistant(buf, "Edited the buffer.")
  end, { response_format = { type = "json_object" } })
end

return M