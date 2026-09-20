---@mod jev-router.conversation In-memory, per-buffer conversation history used
---for multi-turn context and follow-up routing hints.

local config = require("jev-router.config")

local M = {}

---@type table<number, table[]> bufnr -> list of { role, content }
local histories = {}

---Whether conversation tracking is enabled.
---@return boolean
local function enabled()
  return config.get().conversation ~= false
end

---Append a message to a buffer's history, trimming to the configured bound.
---@param bufnr number
---@param role string "user" | "assistant"
---@param content string
function M.append(bufnr, role, content)
  if not enabled() then
    return
  end
  content = vim.trim(content or "")
  if content == "" then
    return
  end

  local h = histories[bufnr]
  if h == nil then
    h = {}
    histories[bufnr] = h
  end
  h[#h + 1] = { role = role, content = content }

  local max = (config.get().conversation_max_turns or 6) * 2
  while #h > max do
    table.remove(h, 1)
  end
end

---Record a user turn.
---@param bufnr number
---@param content string
function M.append_user(bufnr, content)
  M.append(bufnr, "user", content)
end

---Record an assistant turn.
---@param bufnr number
---@param content string
function M.append_assistant(bufnr, content)
  M.append(bufnr, "assistant", content)
end

---The full message list for a buffer (empty when disabled).
---@param bufnr number
---@return table[]
function M.messages(bufnr)
  if not enabled() then
    return {}
  end
  return histories[bufnr] or {}
end

---A short summary of the most recent turns, used to hint the router on
---follow-ups (e.g. "now refactor it").
---@param bufnr number
---@return string|nil summary
function M.summary(bufnr)
  local h = histories[bufnr]
  if h == nil or #h == 0 then
    return nil
  end

  local parts = {}
  local start = math.max(1, #h - 3)
  for i = start, #h do
    parts[#parts + 1] = h[i].role .. ": " .. h[i].content
  end
  return table.concat(parts, "\n")
end

---Reset a buffer's history.
---@param bufnr number
function M.clear(bufnr)
  histories[bufnr] = nil
end

return M