-- Headless test for the quick dial (config validation, `when`, input, row <CR> and dial keys)
-- with a stubbed context and a fake harner module.
--   nvim --headless -u NONE -i NONE -c 'luafile tests/dial.lua'
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.cmd("runtime plugin/ahoy.lua")

local failures = 0
local function check(name, cond)
  print((cond and "ok   " or "FAIL ") .. name)
  if not cond then
    failures = failures + 1
  end
end

local main = function() -- wrapped in xpcall below so an error can't leave nvim hanging
local sent = {}
package.loaded.harner = { ask = function(p) sent[#sent + 1] = p end }

local warnings = {}
local notify = vim.notify
vim.notify = function(msg, level)
  if level and level >= vim.log.levels.WARN then
    warnings[#warnings + 1] = msg
  end
end

local fake_ctx = { cwd = vim.fn.getcwd(), kind = "main" }
require("ahoy.context").detect = function(cb)
  local ctx = vim.deepcopy(fake_ctx)
  ctx.time = os.time()
  vim.schedule(function()
    cb(ctx)
  end)
end

local ran
local only_dial = { header = {}, hero = {}, tickers = {}, cards = { "dial" } }
local ahoy = require("ahoy")
ahoy.setup({
  show_on_startup = false,
  layouts = { main = only_dial, pr = only_dial, global = only_dial },
  dial = {
    { key = "1", label = "Review a PR", harner = "/pr-review {input}", input = "PR: " },
    { key = "2", label = "Address PR", harner = "/address-pr", when = function(c) return c.kind == "pr" end },
    { key = "3", label = "Run fn", run = function(_, input) ran = input or "none" end },
    { key = "4", label = "Boom", run = function() error("kaboom") end },
    { key = "q", label = "Clashes", cmd = "echo 1" },
    { label = "No action" },
    { label = "Two actions", cmd = "echo 1", run = function() end },
    { label = "Bad harner", harner = true },
    { label = "Bad key", key = 5, cmd = "echo 1" },
    { label = "Bad close", cmd = "echo 1", close = "no" },
  },
})

-- config validation
local cfg = ahoy.config
check("valid actions kept", #cfg.dial == 5)
check("clashing key unbound", cfg.dial[5].key == false)
local function warned(pat)
  for _, w in ipairs(warnings) do
    if w:find(pat) then
      return true
    end
  end
end
check("warns: clash", warned('dial key "q" clashes'))
check("warns: no action", warned("dial #6 %(needs exactly one"))
check("warns: two actions", warned("dial #7 %(needs exactly one"))
check("warns: harner type", warned("dial #8 %(harner must be"))
check("warns: key type", warned("dial #9 %(key must be"))
check("warns: close type", warned("dial #10 %(close must be"))

-- dashboard
vim.o.columns = 170
ahoy.open()
local function text()
  return table.concat(vim.api.nvim_buf_get_lines(ahoy._state.buf, 0, -1, false), "\n")
end
local function settled()
  local s = ahoy._state
  if not s.ctx then
    return false
  end
  for _, st in pairs(s.states) do
    if st.status == "loading" then
      return false
    end
  end
  return true
end
vim.wait(3000, settled, 10)
local t = text()
check("dial card shown", t:find("Quick dial") ~= nil)
check("labels with keys", t:find("%[1%] Review a PR") ~= nil and t:find("%[3%] Run fn") ~= nil)
check("`when` hides on main", t:find("Address PR") == nil)

-- dial key with input: {input} substituted, trimmed
vim.ui.input = function(_, cb) cb("  123 ") end
vim.api.nvim_feedkeys("1", "x", false)
check("key 1 sends prompt with input", sent[#sent] == "/pr-review 123")
local function shown()
  local b = ahoy._state.buf
  return b ~= nil and vim.api.nvim_buf_is_valid(b) and vim.api.nvim_get_current_buf() == b
end
check("running an action closes the dashboard", not shown())
local function reopen()
  ahoy.open()
  vim.wait(3000, settled, 10)
end

-- empty input: still runs, placeholder removed (harner gets the trimmed prompt)
reopen()
vim.ui.input = function(_, cb) cb("") end
vim.api.nvim_feedkeys("1", "x", false)
check("empty input", sent[#sent] == "/pr-review")

-- cancelled input aborts (and leaves the dashboard open)
reopen()
local n = #sent
vim.ui.input = function(_, cb) cb(nil) end
vim.api.nvim_feedkeys("1", "x", false)
check("cancel aborts", #sent == n)
check("cancel keeps the dashboard open", shown())

-- hidden action's key does nothing
vim.api.nvim_feedkeys("2", "x", false)
check("hidden action's key is inert", #sent == n)

-- <CR> on a row runs that row's action
local lnum
for i, l in ipairs(vim.api.nvim_buf_get_lines(ahoy._state.buf, 0, -1, false)) do
  if l:find("Run fn") then
    lnum = i
  end
end
vim.api.nvim_win_set_cursor(0, { lnum, 6 })
vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
check("<CR> runs the row action", ran == "none")
check("<CR> closes the dashboard", not shown())

-- errors from a dial key become notifications, not raw errors
reopen()
warnings = {}
local errors = {}
vim.notify = function(msg, level)
  if level == vim.log.levels.ERROR then
    errors[#errors + 1] = msg
  end
end
local ok = pcall(vim.api.nvim_feedkeys, "4", "x", false)
check("dial key error is caught", ok and errors[1] and errors[1]:find("kaboom") ~= nil)

-- pr context shows the `when`-gated action
fake_ctx = { cwd = vim.fn.getcwd(), kind = "pr" }
reopen()
check("`when` shows on pr", text():find("%[2%] Address PR") ~= nil)
vim.api.nvim_feedkeys("2", "x", false)
check("key 2 sends skill", sent[#sent] == "/address-pr")
vim.notify = notify

-- shared keys: unconditional duplicate warns at setup; visible duplicates keep the key on the first only
warnings = {}
vim.notify = function(msg, level)
  if level and level >= vim.log.levels.WARN then
    warnings[#warnings + 1] = msg
  end
end
local hit
ahoy.setup({
  show_on_startup = false,
  layouts = { main = only_dial, pr = only_dial },
  dial = {
    { key = "5", label = "Main five", run = function() hit = "main" end, when = function(c) return c.kind == "main" end },
    { key = "5", label = "Pr five", run = function() hit = "pr" end, when = function(c) return c.kind == "pr" end },
    { key = "6", label = "Six A", run = function() hit = "6a" end },
    { key = "6", label = "Six B", run = function() hit = "6b" end },
    { key = "8", label = "Stay", run = function() hit = "stay" end, close = false },
  },
})
check("warns: shadowed unconditional key", warned('dial key "6" already used') and not warned('dial key "5"'))
vim.notify = notify
fake_ctx = { cwd = vim.fn.getcwd(), kind = "pr" }
ahoy.close() -- the buffer wipes; reopening maps the new keys
ahoy.open()
vim.wait(3000, settled, 10)
t = text()
check("context-split key labelled", t:find("%[5%] Pr five") ~= nil and t:find("Main five") == nil)
check("duplicate shows key once", t:find("%[6%] Six A") ~= nil and t:find("%[6%] Six B") == nil and t:find("Six B") ~= nil)
vim.api.nvim_feedkeys("5", "x", false)
check("context-split key runs the visible one", hit == "pr")
reopen()
vim.api.nvim_feedkeys("6", "x", false)
check("duplicate key runs the labelled one", hit == "6a")
reopen()
vim.api.nvim_feedkeys("8", "x", false)
check("close = false runs and keeps the dashboard open", hit == "stay" and shown())

-- dial section disabled: its keys aren't mapped
ahoy.setup({
  show_on_startup = false,
  layouts = { main = only_dial, pr = only_dial },
  sections = { dial = false },
  dial = { { key = "7", label = "Seven", cmd = "echo 7" } },
})
ahoy.close()
ahoy.open()
vim.wait(3000, settled, 10)
check("disabled dial maps no keys", vim.fn.maparg("7", "n", false, true).buffer ~= 1)

-- nothing configured: the dial is dropped from the layout
ahoy.setup({ show_on_startup = false, layouts = { main = only_dial } })
fake_ctx = { cwd = vim.fn.getcwd(), kind = "main" }
ahoy.close()
reopen()
check("empty dial hidden", text():find("Quick dial") == nil)
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
  print("ERROR " .. tostring(err))
  failures = failures + 1
end
print(failures == 0 and "ALL PASSED" or (failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)
