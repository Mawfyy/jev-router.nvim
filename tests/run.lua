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
eq(p.questions.complexity.type, "choice", "payload asks a parallel complexity question")

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

-- parse_answers returns every question
local multresp = '{"model":"m","answers":{'
  .. '"intent":{"type":"choice","choice":"general_question","confidence":0.8,"probabilities":{}},'
  .. '"complexity":{"type":"choice","choice":"deep","confidence":0.9,"probabilities":{}}}}'
local all, aerr = api.parse_answers(multresp)
eq(aerr, nil, "parse_answers returns no error")
eq(all.intent.choice, "general_question", "parse_answers extracts intent")
eq(all.complexity.choice, "deep", "parse_answers extracts complexity")

-- ----------------------------------------------------- file choice payload
local fp = api.build_choice_payload("open drivers code", "file", "which file?", {
  ["/a/b/drivers.lua"] = "/a/b/drivers.lua",
})
eq(fp.state, "open drivers code", "file payload.state is the prompt")
eq(fp.questions.file.type, "choice", "file payload question is a choice")
eq(fp.questions.file.criteria["/a/b/drivers.lua"], "/a/b/drivers.lua",
  "file payload carries criteria")

-- parse_question extracts a non-intent question
local fresp = '{"model":"m","answers":{"file":{"type":"choice",'
  .. '"choice":"/a/b/drivers.lua","confidence":0.88,'
  .. '"probabilities":{"/a/b/drivers.lua":0.88}}}}'
local fansw, ferr = api.parse_question(fresp, "file")
eq(ferr, nil, "parse_question file returns no error")
eq(fansw.choice, "/a/b/drivers.lua", "parse_question extracts choice")
eq(fansw.confidence, 0.88, "parse_question extracts confidence")

-- parse (default) still reads the intent question
local ip, ie = api.parse(okresp)
eq(ie, nil, "parse default question returns no error")
eq(ip.choice, "run_command", "parse default extracts intent choice")

-- ----------------------------------------------------- run_command cleaning
local rc = require("jev-router.handlers.run_command")
eq(rc.clean("```bash\nmake test\n```"), "make test", "clean strips fenced block")
eq(rc.clean("  npm test  "), "npm test", "clean trims whitespace")
eq(rc.clean("$ make test"), "make test", "clean strips shell prompt")
eq(rc.clean("`make test`"), "make test", "clean strips backticks")

-- ----------------------------------------------------- edit_code content
local ec = require("jev-router.handlers.edit_code")
eq(ec.extract_content("```lua\nlocal x = 1\nreturn x\n```"), "local x = 1\nreturn x",
  "extract_content strips a fenced block")
eq(ec.extract_content("no fence here"), "no fence here",
  "extract_content returns text verbatim when unfenced")

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
    stdout = '{"model":"x","answers":{'
      .. '"intent":{"type":"choice","choice":"edit_code","confidence":0.95,"probabilities":{"edit_code":1.0}},'
      .. '"complexity":{"type":"choice","choice":"deep","confidence":0.9,"probabilities":{}}}}',
    stderr = "",
  })
end

local dispatched = {}
local dispatched_complexity = nil
init.setup({
  api_key = "k",
  confidence_threshold = 0.6,
  route_handlers = {
    edit_code = function(prompt, answer)
      table.insert(dispatched, "edit_code:" .. prompt)
      dispatched_complexity = answer and answer.complexity
    end,
  },
})
init.ask("refactor this function")

-- Handlers are dispatched via vim.schedule (out of the fast event context),
-- so wait for the scheduled task to run.
vim.wait(1000, function() return #dispatched == 1 end)

ok(seen.args ~= nil, "vim.system invoked with curl args")
eq(#dispatched, 1, "exactly one route dispatched")
ok(dispatched[1] == "edit_code:refactor this function", "routed to edit_code")
eq(dispatched_complexity, "deep", "complexity answer threaded to handler")

-- restore
vim.system = orig_system

-- ------------------------------------------------- interface: chat backend
local backend_called = nil
config.setup({ chat_backend = function(models, messages, cb)
  backend_called = models
  cb("fake-reply", nil)
end })
local chat_text = nil
api.chat("gpt-x", { { role = "user", content = "hi" } }, function(text)
  chat_text = text
end)
eq(backend_called, "gpt-x", "api.chat delegates to configured chat_backend")
eq(chat_text, "fake-reply", "chat backend reply delivered to callback")

-- ------------------------------------------------- interface: file provider
local files = require("jev-router.files")
local listed = nil
config.setup({ file_provider = { list = function(cb) cb({ "/fake/a.lua" }) end } })
files.gather_candidates(function(c)
  listed = c
end)
eq(#listed, 1, "gather_candidates delegates to configured file_provider")
eq(listed[1], "/fake/a.lua", "file provider list delivered to callback")

-- ----------------------------------------- context does not require network
-- (file provider + buffer only; read_bounded is pure io)
local tmp = vim.fn.tempname()
local tf = assert(io.open(tmp, "w"))
tf:write("hello world")
tf:close()
local truncated = files.read_bounded(tmp, 5)
ok(truncated ~= nil and truncated:sub(1, 5) == "hello" and #truncated > 5,
  "read_bounded truncates long content")
eq(files.read_bounded(tmp, 100), "hello world", "read_bounded returns full short content")
os.remove(tmp)

-- ----------------------------------------------------------------- summary
log(string.format("RESULT: %d passed, %d failed", passed, failed))
f:close()

if failed > 0 then
  vim.cmd("cq")
end