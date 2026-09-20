---@mod jev-router.handlers.read_file Semantically resolve and open the file a
---prompt refers to.

local config = require("jev-router.config")
local api = require("jev-router.api")

local M = {}

---Collect open buffer names, deduped and normalized to absolute paths.
---@return string[] paths
local function buffer_candidates()
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
local function git_ls_files_args()
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
function M.gather_candidates(callback)
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

  for _, buf in ipairs(buffer_candidates()) do
    add(buf)
  end

  local git_args = git_ls_files_args()
  local args = git_args
    or { "find", ".", "-type", "f" }

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

---Open a file in a vertical split with line numbers enabled, keeping focus on
---the new window.
---@param path string
function M.open(path)
  path = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(path) == 0 then
    config.get().on_error("file_not_readable: " .. path)
    return
  end

  vim.cmd("vsplit " .. vim.fn.fnameescape(path))

  vim.wo.number = true
  vim.wo.relativenumber = true
  vim.wo.cursorline = true
end

---Offer the user a picker over the candidates when confidence is too low.
---@param candidates string[]
---@param prompt string
local function choose_from_picker(candidates, prompt)
  vim.ui.select(candidates, {
    prompt = "Open file (unclear which one: " .. prompt .. ")",
    format_item = function(item)
      return vim.fn.fnamemodify(item, ":~:.")
    end,
  }, function(choice)
    if choice ~= nil then
      M.open(choice)
    end
  end)
end

---Semantically resolve which file a prompt refers to and open it.
---@param prompt string
function M.run(prompt)
  -- The decisions callback (on_exit in api.lua) runs in a fast event context
  -- where nvim_list_bufs/open_win are forbidden; re-enter the main loop.
  vim.schedule(function()
    M.gather_candidates(function(candidates)
      if #candidates == 0 then
        config.get().on_error("no_candidates")
        return
      end

      api.select_file(candidates, prompt, function(parsed, err)
        local function handle()
          if err then
            if #candidates == 1 then
              M.open(candidates[1])
            else
              choose_from_picker(candidates, prompt)
            end
            return
          end

          local choice = parsed and parsed.choice
          local confidence = parsed and parsed.confidence or 0
          local threshold = config.get().confidence_threshold or 0.6

          if choice == nil then
            choose_from_picker(candidates, prompt)
            return
          end

          if confidence < threshold then
            config.get().on_uncertain("read_file", confidence)
            choose_from_picker(candidates, prompt)
            return
          end

          M.open(choice)
        end

        vim.schedule(handle)
      end)
    end)
  end)
end

return M