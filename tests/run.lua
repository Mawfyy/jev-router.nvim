-- Self-contained unit tests for jev-router.nvim. Runs with `-u NONE`, no
-- plenary/busted required. Output goes to a file; exits non-zero on failure.
--
-- Run: nvim --headless -u NONE -l tests/run.lua

local OUT = "/tmp/jev-router-test.txt"
local f = assert(io.open(OUT, "w"))

local passed = 0
local failed = 0

local function log(...)
  f:write(table.concat({ ... }, " "), "\n")
  f:flush()
end

local function ok(cond, msg)
  if cond then
    passed = passed + 1
    log("PASS: " .. msg)
  else
    failed = failed + 1
    log("FAIL: " .. msg)
  end
end

local function eq(a, b, msg)
  ok(a == b, string.format("%s (got %q, want %q)", msg, tostring(a), tostring(b)))
end

local plugin = vim.fn.getcwd() ~= "/" and vim.fn.getcwd()
  or "/home/mawfy/Projects/jev-router.nvim"
package.path = plugin .. "/lua/?.lua;" .. plugin .. "/lua/?/init.lua;" .. package.path

local config = require("jev-router.config")
local api = require("jev-router.api")

-- ---------------------------------------------------------------- config

local cfg = config.setup({ api_key = "explicit-key", model = "custom/model" })
eq(cfg.api_key, "explicit-key", "config.api_key honors explicit value")
eq(cfg.model, "custom/model", "config.model honors override")
eq(cfg.endpoint, "https://openrouter.ai/api/alpha/decisions", "config.endpoint default")

-- env fallback on a fresh config with no explicit/default key
vim.env.OPENROUTER_API_KEY = "env-key"
local fresh_config = require("jev-router.config")
-- reset accumulated user opts and clear the built-in default key
fresh_config._user_opts = {}
fresh_config.defaults.api_key = nil
fresh_config.setup({})
eq(fresh_config.get().api_key, "env-key", "config.api_key falls back to env var")
vim.env.OPENROUTER_API_KEY = nil

-- api_key accessor
eq(fresh_config.api_key(), "env-key", "config.api_key() accessor")

-- explicit endpoint/model override the default
fresh_config._user_opts = {}
fresh_config.setup({ endpoint = "https://custom/x", model = "my/model" })
eq(fresh_config.get().endpoint, "https://custom/x", "explicit endpoint wins over default")
eq(fresh_config.get().model, "my/model", "explicit model wins over default")

-- ---------------------------------------------------------------- payload
local p = api.build_payload("run the tests")
eq(p.state, "run the tests", "payload.state is the prompt")
eq(p.questions.intent.type, "choice", "payload question type is choice")
eq(vim.tbl_count(p.questions.intent.criteria), 4, "payload has 4 intent criteria")

-- ------------------------------------------------------------------ parse
local okresp = '{"model":"typesafe/jev-1.13",'
  .. '"answers":{"intent":{"type":"choice","choice":"run_command",'
  .. '"confidence":0.9,"probabilities":{"run_command":0.9,"general_question":0.1}}},'
  .. '"usage":{"input_tokens":10,"output_tokens":3}}'
local ans, perr = api.parse(okresp)
eq(perr, nil, "parse ok response returns no error")
eq(ans.choice, "run_command", "parse extracts choice")
eq(ans.confidence, 0.9, "parse extracts confidence")
eq(ans.probabilities.general_question, 0.1, "parse extracts probabilities")

local _, e1 = api.parse('{"error":{"code":401,"message":"bad key"}}')
eq(e1, "api_error:401:bad key", "parse surfaces API error")

local _, e2 = api.parse("not json")
eq(e2, "bad_json", "parse surfaces malformed body")

local _, e3 = api.parse('{"answers":{}}')
eq(e3, "bad_json", "parse surfaces missing intent answer")

-- ------------------------------------------------------------- routing
-- Drive the router without a network call by re-implementing init.run via the
-- exported classify path with vim.system stubbed.
local init = require("jev-router.init")

local seen = {}
local orig_system = vim.system
vim.system = function(args, opts, on_exit)
  seen.args = args
  on_exit({
    code = 0,
    stdout = '{"model":"x","answers":{"intent":{"type":"choice",'
      .. '"choice":"edit_code","confidence":0.95,"probabilities":{"edit_code":1.0}}}}',
    stderr = "",
  })
end

local notified = {}
local orig_notify = vim.notify
vim.notify = function(msg, level)
  table.insert(notified, msg)
end

init.setup({ api_key = "k", confidence_threshold = 0.6 })
init.ask("refactor this function")

ok(seen.args ~= nil, "vim.system invoked with curl args")
ok(#notified > 0, "route handler notified")
eq(vim.tbl_count(notified), 1, "exactly one route notified")
ok(type(notified[1]) == "string" and notified[1]:find("edit_code", 1, true) ~= nil,
  "routed to edit_code")

-- restore
vim.system = orig_system
vim.notify = orig_notify

-- ----------------------------------------------------------------- summary
log(string.format("RESULT: %d passed, %d failed", passed, failed))
f:close()

if failed > 0 then
  vim.cmd("cq")
end