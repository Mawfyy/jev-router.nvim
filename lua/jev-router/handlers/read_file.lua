---@mod jev-router.handlers.read_file Semantically resolve and open the file a
---prompt refers to.

local config = require("jev-router.config")
local api = require("jev-router.api")
local files = require("jev-router.files")

local M = {}

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
  files.gather_candidates(function(candidates)
    if #candidates == 0 then
      config.get().on_error("no_candidates")
      return
    end

    api.select_file(candidates, prompt, function(parsed, err)
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
    end)
  end)
end

return M