---@mod jev-router.files Shared project-file discovery and context gathering.

local config = require("jev-router.config")

local M = {}

---Collect open buffer names, deduped and normalized to absolute paths.
---@return string[] paths
function M.buffer_candidates()
  local seen = {}
  local out = {}

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= nil and name ~= "" then
        local abs = vim.fn.fnamemodify(name, ":p")
        if not seen[abs] then
          seen[abs] = true
          table.insert(out, abs)
        end
      end
    end
  end

  return out
end

---Create the `git ls-files` system command for gathering project files.
---@return table args|nil nil when git is unavailable
function M.git_ls_files_args()
  if vim.fn.executable("git") == 0 then
    return nil
  end

  local cwd = vim.fn.getcwd()
  local res = vim.system({ "git", "-C", cwd, "rev-parse", "--is-inside-work-tree" }, { text = true }):wait()
  if res == nil or vim.fn.trim(res.stdout or "") ~= "true" then
    return nil
  end

  return { "git", "-C", cwd, "ls-files", "--cached", "--others", "--exclude-standard" }
end

---Gather candidate files: open buffers first, then git-tracked project files.
---Falls back to `find` when git is unavailable. Results are absolute, deduped,
---and capped at `file_candidates_max`.
---@param callback fun(candidates: string[])
function M.git_list(callback)
  local max = config.get().file_candidates_max or 100
  local seen = {}
  local out = {}

  local function add(name)
    local abs = vim.fn.fnamemodify(vim.trim(name), ":p")
    if abs == "" or seen[abs] then
      return
    end
    seen[abs] = true
    table.insert(out, abs)
  end

  for _, buf in ipairs(M.buffer_candidates()) do
    add(buf)
  end

  local git_args = M.git_ls_files_args()
  local args = git_args or { "find", ".", "-type", "f" }

  ---@param obj vim.SystemCompleted
  local function on_exit(obj)
    if obj.code ~= 0 then
      -- Fall back to find only if git itself failed (not "not a repo").
      if git_args and args[1] == "git" then
        vim.system({ "find", ".", "-type", "f" }, {},
          function(o2)
            if o2.code == 0 then
              for line in (o2.stdout or ""):gmatch("[^\r\n]+") do
                if #out < max then add(line) end
              end
            end
            callback(out)
          end)
        return
      end
      callback(out)
      return
    end

    for line in (obj.stdout or ""):gmatch("[^\r\n]+") do
      if #out < max then add(line) end
    end

    callback(out)
  end

  vim.system(args, {}, on_exit)
end

---The built-in file provider (git-tracked files + open buffers).
---@type jev-router.FileProvider
M.git_provider = {
  list = M.git_list,
}

---Gather candidate files via the configured `file_provider` (or the built-in
---git provider). Results are absolute paths.
---@param callback fun(candidates: string[])
function M.gather_candidates(callback)
  local provider = config.get().file_provider
  if provider ~= nil and provider.list ~= nil then
    return provider.list(callback)
  end
  return M.git_provider.list(callback)
end

---Read a file's contents, bounded to `max` bytes, appending a truncation marker
---when longer. Deterministic pure-I/O helper (no vim.api); testable without
---stubbing.
---@param path string
---@param max integer
---@return string|nil content nil when unreadable
function M.read_bounded(path, max)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local content = f:read(max + 1)
  f:close()
  if content == nil then
    return nil
  end
  if #content > max then
    content = content:sub(1, max) .. "\n… truncated"
  end
  return content
end

---Gather a bounded context package for answering project questions:
---`buffer` (active buffer text), `tree` (relative file list), and `files`
---(contents of the configured key files). Respects `context_max_*` limits.
---@param callback fun(ctx: { buffer: string, tree: string, files: table<string, string> })
function M.gather_context(callback)
  local cfg = config.get()
  local max_chars = cfg.context_max_chars or 20000
  local key_files = cfg.context_key_files or {}

  local ctx = {
    buffer = "",
    tree = "",
    files = {},
  }

  -- Active buffer text.
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local buftext = table.concat(lines, "\n")
  if #buftext > max_chars then
    buftext = buftext:sub(1, max_chars) .. "\n… truncated"
  end
  ctx.buffer = buftext

  local function add_file(path, content)
    if #ctx.files >= 10 then
      return
    end
    ctx.files[path] = content
  end

  M.gather_candidates(function(candidates)
    -- gather_candidates' callback runs in the file provider's vim.system
    -- on_exit (fast event context), where getcwd/fnamemodify twist is
    -- restricted. Re-enter the main loop before building the context.
    vim.schedule(function()
      local cwd = vim.fn.getcwd()
      local rels = {}
      local seen = {}
      local budget = max_chars
      for _, abs in ipairs(candidates) do
        if budget <= 0 then
          break
        end
        local rel = abs:sub(1, #cwd) == cwd and abs:sub(#cwd + 2) or abs
        if rel ~= "" and not seen[rel] then
          seen[rel] = true
          rels[#rels + 1] = rel
          budget = budget - #rel - 1
        end
      end
      ctx.tree = table.concat(rels, "\n")

      -- Inject key file contents when present among candidates.
      for _, abs in ipairs(candidates) do
        if #ctx.files >= 10 then
          break
        end
        local base = vim.fn.fnamemodify(abs, ":t")
        for _, key in ipairs(key_files) do
          if base == key then
            local content = M.read_bounded(abs, math.min(8000, max_chars))
            if content ~= nil then
              add_file(abs, content)
            end
            break
          end
        end
      end

      callback(ctx)
    end)
  end)
end

return M