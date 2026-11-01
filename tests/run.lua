-- Headless smoke test with fake `sleep` sections.
--   nvim --headless -u NONE -i NONE -c 'luafile tests/run.lua'
-- (not `-l`: in that mode 'columns' can't be resized, which the reflow checks need)
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.cmd("runtime plugin/ahoy.lua")

local failures = 0
local function check(name, cond)
  print((cond and "ok   " or "FAIL ") .. name)
  if not cond then
    failures = failures + 1
  end
end

local function sleep(ms, data, err)
  return function(_, done)
    vim.defer_fn(function()
      done(data, err)
    end, ms)
  end
end

local acted = false
local L = {
  header = "status",
  hero = { "empty", "slow" },
  tickers = { "tick", "empty" },
  cards = { "slow", "fails", "empty", "throws", "badrender", "hidden", "missing" },
}
require("ahoy").setup({
  show_on_startup = false,
  sections = {
    {
      name = "slow",
      fetch = sleep(300, { "first row", "second row" }),
      render = function(d)
        return {
          lines = d,
          highlights = { { 1, 0, 5, "AhoyOk" } },
          keymaps = { [1] = { ["<CR>"] = function() acted = true end } },
        }
      end,
    },
    { name = "fails", fetch = sleep(50, nil, "boom"), render = function() return {} end },
    { name = "empty", fetch = sleep(50, nil), render = function() return {} end },
    { name = "throws", fetch = function() error("kaboom") end, render = function() return {} end },
    { name = "badrender", fetch = sleep(10, true), render = function() error("render oops") end },
    { name = "tick", slots = { "ticker" }, fetch = sleep(10, "tick tock"), render = function(d) return { d } end },
    { name = "hidden", when = function() return false end, render = function() return { "never" } end },
  },
  layouts = { main = L, pr = L, global = L },
})

local ahoy = require("ahoy")
ahoy.open()
local buf = vim.api.nvim_get_current_buf()
local function lines()
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end
local function text()
  return table.concat(lines(), "\n")
end

check(":Ahoy command exists", vim.fn.exists(":Ahoy") == 2)
check("filetype ahoy", vim.bo[buf].filetype == "ahoy")
check("nofile buffer", vim.bo[buf].buftype == "nofile")
vim.wait(200, function() return text():find("loading…") ~= nil end, 10)
check("spinner/loading while fetching", text():find("loading…") ~= nil)

vim.wait(5000, function()
  local t = text()
  return not t:find("loading…") and not t:find("detecting")
end, 20)
local t = text()
check("slow card rendered", t:find("first row") and t:find("second row"))
check("hero falls back past empty", t:match("╭─ slow") ~= nil)
check("error card", t:find("✗ boom") ~= nil)
check("fetch throw caught", t:find("kaboom") ~= nil)
check("render throw caught", t:find("render oops") ~= nil)
check("empty card", t:find("nothing here") ~= nil)
check("ticker", t:find("tick tock") ~= nil)
check("when=false hidden", t:find("never") == nil)
check("status header", t:find("⎇") ~= nil)
check("footer legend", t:find("refresh") ~= nil)
check("footer timings", t:find("slow %d+ms") ~= nil)

local function two_up()
  for _, l in ipairs(lines()) do
    local _, n = l:gsub("╭─", "")
    if n >= 2 then
      return true
    end
  end
  return false
end
vim.o.columns = 170
vim.cmd("doautocmd VimResized")
check("window is 170 wide", vim.api.nvim_win_get_width(0) == 170)
check("two columns at 170", two_up())

-- every line fits the window
local function fits()
  local w = vim.api.nvim_win_get_width(0)
  for _, l in ipairs(lines()) do
    if vim.fn.strdisplaywidth(l) > w then
      return false
    end
  end
  return true
end
check("lines fit at 170", fits())

-- <CR> runs the row action
for i, l in ipairs(lines()) do
  local col = l:find("first row", 1, true)
  if col then
    vim.api.nvim_win_set_cursor(0, { i, col - 1 })
    break
  end
end
vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
check("<CR> row action", acted)

-- reflow
vim.o.columns = 90
vim.cmd("doautocmd VimResized")
check("one column at 90", not two_up())
check("lines fit at 90", fits())

-- :Ahoy again refreshes
vim.cmd("Ahoy")
check("refresh shows spinner", text():find("detecting") ~= nil or text():find("loading…") ~= nil)
vim.wait(5000, function() return not text():find("loading…") and not text():find("detecting") end, 20)

-- q leaves and wipes
vim.api.nvim_feedkeys("q", "x", false)
check("q wipes dashboard", not vim.api.nvim_buf_is_valid(buf))
check("timers stopped", ahoy._state.spin == nil and ahoy._state.clock == nil)

print(failures == 0 and "ALL PASSED" or (failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)
