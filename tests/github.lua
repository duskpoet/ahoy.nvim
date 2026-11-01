-- Headless test for the GitHub sections with a stubbed `gh api graphql`.
--   nvim --headless -u NONE -i NONE -c 'luafile tests/github.lua'
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.cmd("runtime plugin/ahoy.lua")

local failures = 0
local function check(name, cond)
  print((cond and "ok   " or "FAIL ") .. name)
  if not cond then
    failures = failures + 1
  end
end

local util = require("ahoy.util")
local context = require("ahoy.context")

-- util / context helpers ------------------------------------------------------
check("iso_to_epoch Z", util.iso_to_epoch("1970-01-02T00:00:00Z") == 86400)
check("iso_to_epoch 2026", util.iso_to_epoch("2026-10-31T13:14:23Z") == 1793452463)
check("iso_to_epoch offset", util.iso_to_epoch("2026-10-31T15:14:23+02:00") == 1793452463)
check("iso_to_epoch garbage", util.iso_to_epoch("nope") == nil)
check("ago", util.ago(1000, 1000 + 3 * 3600) == "3h" and util.ago(1000, 1010) == "now"
  and util.ago(0, 86400 * 20) == "2w")
check("remote scp", context._parse_remote("git@github.com:owner/name.git") == "owner/name")
check("remote https", context._parse_remote("https://github.com/owner/name") == "owner/name")
check("remote ssh url", context._parse_remote("ssh://git@github.com/owner/name.git") == "owner/name")
check("remote junk", context._parse_remote("/tmp/some/path") == nil)

-- fixture ---------------------------------------------------------------------
local now = os.time()
local function iso(ago)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", now - ago)
end
local function check_run(name, conclusion, run)
  return { __typename = "CheckRun", name = name, status = "COMPLETED", conclusion = conclusion,
    detailsUrl = "https://ci/" .. name, checkSuite = { workflowRun = { databaseId = run } } }
end
local function pr(o)
  return vim.tbl_extend("force", {
    isDraft = false, updatedAt = iso(3600), baseRefName = "main", headRefName = "feat-" .. o.number,
    author = { login = "me" }, repository = { nameWithOwner = "acme/app" },
    url = "https://github.com/acme/app/pull/" .. o.number, mergeable = "MERGEABLE", mergeStateStatus = "CLEAN",
    commits = { nodes = { { commit = { statusCheckRollup = { state = "SUCCESS", contexts = { nodes = {
      check_run("lint", "SUCCESS", 1), check_run("test", "SUCCESS", 1) } } } } } } },
    reviewThreads = { nodes = {} },
    timelineItems = { nodes = {} },
  }, o)
end

local fixture = {
  viewer = { login = "me" },
  mine = { nodes = {
    pr({ number = 1, title = "Ready one", reviewDecision = "APPROVED",
      timelineItems = { nodes = {
        { __typename = "PullRequestReview", author = { login = "alice" }, submittedAt = iso(600), state = "APPROVED",
          url = "https://r/1", bodyText = "LGTM" },
        { __typename = "IssueComment", author = { login = "me" }, createdAt = iso(500), url = "https://c/self", bodyText = "thanks" },
        { __typename = "IssueComment", author = { __typename = "Bot", login = "github-actions" }, createdAt = iso(60),
          url = "https://c/bot", bodyText = "Terraform Plan" },
      } } }),
    pr({ number = 2, title = "Broken build", reviewDecision = "REVIEW_REQUIRED",
      repository = { nameWithOwner = "acme/other" },
      commits = { nodes = { { commit = { statusCheckRollup = { state = "FAILURE", contexts = { nodes = {
        check_run("lint", "SUCCESS", 7), check_run("unit tests", "FAILURE", 42),
        { __typename = "StatusContext", context = "deploy", state = "PENDING" } } } } } } } } }),
    pr({ number = 3, title = "Has threads", reviewDecision = "CHANGES_REQUESTED", isDraft = true,
      reviewThreads = { nodes = {
        { isResolved = false, path = "lua/x.lua", line = 12, comments = { nodes = {
          { author = { login = "bob" }, createdAt = iso(120), url = "https://t/1", bodyText = "why this?" } } } },
        { isResolved = false, path = "lua/y.lua", line = 3, comments = { nodes = {
          { author = { login = "me" }, createdAt = iso(100), url = "https://t/2", bodyText = "done" } } } },
        { isResolved = true, path = "lua/z.lua", line = 1, comments = { nodes = {} } },
      } } }),
  } },
  requested = { nodes = {
    { number = 9, title = "Please review me", url = "https://github.com/acme/app/pull/9", updatedAt = iso(7200),
      author = { login = "carol" }, repository = { nameWithOwner = "acme/app" }, baseRefName = "main", headRefName = "c" },
  } },
  mentions = { nodes = {
    { __typename = "Issue", number = 77, title = "Ping about thing", url = "https://github.com/acme/app/issues/77",
      updatedAt = iso(86400 * 2), author = { login = "dave" }, repository = { nameWithOwner = "acme/app" } },
  } },
}

-- normalize -------------------------------------------------------------------
local gh = require("ahoy.gh")
local m = gh.normalize(vim.deepcopy(fixture))
check("normalize mine", #m.mine == 3 and #m.requested == 1 and #m.mentions == 1)
check("ci failing", gh.ci_failing(m.mine[2]) and not gh.ci_failing(m.mine[1]))
check("ci counts", m.mine[2].ci.total == 3 and m.mine[2].ci.passed == 1 and m.mine[2].ci.pending == 1)
check("failing run id", m.mine[2].ci.failing[1].run_id == 42)
check("ready to merge", gh.ready_to_merge(m.mine[1]) and not gh.ready_to_merge(m.mine[2]))
check("waiting threads", m.mine[3].waiting_threads == 1 and #m.mine[3].threads == 2)
check("events exclude me", #vim.tbl_filter(function(e) return e.who == "me" end, m.events) == 0)
check("events sorted", m.events[1].who == "github-actions" and m.events[1].bot and m.events[2].who == "bob")
local waiting = require("ahoy.sections.waiting")
local capped = waiting._items(m, 0)
check("review cap collapses", capped[1].kind == "older" and capped[1].n == 1)
check("ref", gh.ref(m.mine[1], "acme/app") == "#1" and gh.ref(m.mine[2], "acme/app") == "other#2")

-- dashboard with stubbed gh ---------------------------------------------------
local calls = 0
gh.graphql = function(q, vars, cb)
  calls = calls + 1
  check("query vars", vars.mine:find("author:@me") and vars.req:find("review%-requested:@me") and vars.n == 30)
  vim.defer_fn(function()
    cb(vim.deepcopy(fixture))
  end, 50)
end

local L = { header = "status", cards = { "waiting", "my_prs", "latest" }, tickers = { "my_prs", "waiting" } }
require("ahoy").setup({ show_on_startup = false, layouts = { main = L, pr = L, global = L } })
vim.o.columns = 200
local ahoy = require("ahoy")
ahoy.open()
local buf = vim.api.nvim_get_current_buf()
local function text()
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end
vim.wait(5000, function()
  local t = text()
  return not t:find("loading…") and not t:find("detecting") and not t:find("⠋")
end, 20)
local t = text()
check("one graphql call for all sections", calls == 1)
check("waiting card", t:find("Waiting on me") ~= nil)
check("review request row", t:find("review") and t:find("Please review me") and t:find("carol"))
check("threads row", t:find("1 thread") ~= nil)
check("failing ci row", t:find("other#2 ⟨unit tests⟩ Broken build") ~= nil)
check("merge row", t:find("merge") and t:find("Ready one"))
check("mention row", t:find("Ping about thing") ~= nil)
check("my prs ci count", t:find("1/3") ~= nil)
check("my prs review/draft tags", t:find("approved · ") and t:find("draft · "))
if os.getenv("AHOY_DUMP") then
  print(t)
end
check("latest", t:find("bob replied") and t:find("alice approved"))
check("latest hides self", t:find("thanks") == nil)
check("latest hides bots", t:find("Terraform Plan") == nil)
check("ticker summary", t:find("3 open") ~= nil)
check("lines fit", (function()
  for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if vim.fn.strdisplaywidth(l) > vim.api.nvim_win_get_width(0) then
      return false
    end
  end
  return true
end)())

-- actions: <CR> on the mention row opens the browser; on failing CI fetches the run log
local opened, ran = nil, nil
vim.ui.open = function(url)
  opened = url
end
local actions = require("ahoy.actions")
local orig_log = actions.log_failed
actions.log_failed = function(check_, repo)
  ran = { check_.run_id, repo }
end
local function press_on(needle, key)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local col = l:find(needle, 1, true)
    if col then
      vim.api.nvim_win_set_cursor(0, { i, col - 1 })
      vim.api.nvim_feedkeys(vim.keycode(key), "x", false)
      return true
    end
  end
end
press_on("Ping about thing", "<CR>")
check("<CR> mention → browser", opened == "https://github.com/acme/app/issues/77")
press_on("⟨unit tests⟩", "<CR>")
check("<CR> failing CI → run log", ran and ran[1] == 42 and ran[2] == "acme/other")
opened = nil
press_on("⟨unit tests⟩", "o")
check("o failing CI → browser", opened == "https://ci/unit tests")
actions.log_failed = orig_log

-- error surfacing
gh.graphql = function(_, _, cb)
  vim.schedule(function()
    cb(nil, "HTTP 401: Bad credentials")
  end)
end
ahoy.refresh()
vim.wait(3000, function() return text():find("Bad credentials") ~= nil end, 20)
check("error surfaced in card", text():find("✗ HTTP 401: Bad credentials") ~= nil)

print(failures == 0 and "ALL PASSED" or (failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)
