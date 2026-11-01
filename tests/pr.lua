-- Headless test for the PR view (pr hero, threads, activity) with stubbed context + gh,
-- and the "no PR yet" hero against a throwaway git repo.
--   nvim --headless -u NONE -i NONE -c 'luafile tests/pr.lua'
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
local now = os.time()
local function iso(ago)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", now - ago)
end
local function run(name, conclusion, id, started, done_)
  return { __typename = "CheckRun", name = name, status = conclusion and "COMPLETED" or "IN_PROGRESS",
    conclusion = conclusion, detailsUrl = "https://ci/" .. name .. "/" .. id, startedAt = iso(started),
    completedAt = done_ and iso(done_) or nil, checkSuite = { workflowRun = { databaseId = id } } }
end

local function fixture(o)
  o = o or {}
  return {
    viewer = { login = "me" },
    repository = { pullRequest = vim.tbl_extend("force", {
      number = 42, title = "Make it faster", url = "https://github.com/acme/app/pull/42", state = "OPEN",
      isDraft = false, createdAt = iso(86400 * 3), updatedAt = iso(600), baseRefName = "main", headRefName = "feat",
      additions = 120, deletions = 30, changedFiles = 8, reviewDecision = "CHANGES_REQUESTED",
      mergeable = "MERGEABLE", mergeStateStatus = "BLOCKED", author = { login = "me" },
      repository = { nameWithOwner = "acme/app" },
      allCommits = { totalCount = 5 },
      commits = { nodes = { { commit = { oid = "abc", committedDate = iso(7200), statusCheckRollup = {
        state = "FAILURE", contexts = { nodes = {
          run("lint", "CANCELLED", 1, 9000, 8990), -- stale, superseded by the re-run below
          run("lint", "SUCCESS", 2, 5000, 4000),
          run("unit", "FAILURE", 3, 5000, 3000),
          run("e2e", nil, 4, 1000),
        } } } } } } },
      latestReviews = { nodes = {
        { author = { login = "alice" }, state = "APPROVED", submittedAt = iso(5000) },
        { author = { login = "bob" }, state = "CHANGES_REQUESTED", submittedAt = iso(4000) },
        { author = { __typename = "Bot", login = "cursor" }, state = "COMMENTED", submittedAt = iso(3500) },
      } },
      reviewRequests = { nodes = {
        { requestedReviewer = { __typename = "User", login = "alice" } }, -- re-requested
        { requestedReviewer = { __typename = "Team", name = "core" } },
      } },
      reviewThreads = { nodes = {
        { isResolved = false, isOutdated = false, path = "src/b.lua", line = 3,
          comments = { totalCount = 2, nodes = { { author = { login = "bob" }, bodyText = "rename this", createdAt = iso(4000), url = "https://t/b" } } },
          last = { nodes = { { author = { login = "me" }, createdAt = iso(3000) } } } },
        { isResolved = false, isOutdated = true, path = "src/a.lua", line = nil, originalLine = 2,
          comments = { totalCount = 1, nodes = { { author = { login = "bob" }, bodyText = "why?", createdAt = iso(4000), url = "https://t/a" } } },
          last = { nodes = { { author = { login = "bob" }, createdAt = iso(4000) } } } },
        { isResolved = true, path = "src/c.lua", line = 1, comments = { totalCount = 1, nodes = {} }, last = { nodes = {} } },
      } },
      timelineItems = { nodes = {
        { __typename = "PullRequestCommit", url = "https://c/1",
          commit = { abbreviatedOid = "abc1234", committedDate = iso(7200), messageHeadline = "speed up", author = { user = { login = "me" } } } },
        { __typename = "ReviewRequestedEvent", actor = { login = "me" }, createdAt = iso(6000), requestedReviewer = { name = "core" } },
        { __typename = "PullRequestReview", author = { login = "bob" }, submittedAt = iso(4000), state = "CHANGES_REQUESTED", url = "https://r/bob", bodyText = "needs work" },
        { __typename = "IssueComment", author = { __typename = "Bot", login = "github-actions" }, createdAt = iso(100), url = "https://c/bot", bodyText = "Plan output" },
        { __typename = "HeadRefForcePushedEvent", actor = { login = "me" }, createdAt = iso(2000), afterCommit = { abbreviatedOid = "def5678" } },
      } },
    }, o) },
  }
end

-- normalize ------------------------------------------------------------------
local gh = require("ahoy.gh")
local m = gh.normalize_pr(fixture())
local pr = m.pr
check("re-runs collapse", pr.ci.total == 3 and pr.ci.passed == 1 and pr.ci.pending == 1 and #pr.ci.failing == 1)
check("failing check is unit", pr.ci.failing[1].name == "unit" and pr.ci.failing[1].run_id == 3)
check("diffstat", pr.additions == 120 and pr.deletions == 30 and pr.files == 8 and pr.commits == 5)
local rv = {}
for _, r in ipairs(pr.reviewers) do
  rv[r.who] = r
end
check("re-request overrides review", rv.alice.state == "PENDING" and rv.alice.was == "APPROVED")
check("changes requested kept", rv.bob.state == "CHANGES_REQUESTED")
check("team reviewer", rv["@core"] and rv["@core"].team)
check("threads sorted + unresolved only", #pr.threads == 2 and pr.threads[1].path == "src/a.lua")
check("thread waiting flags", pr.threads[1].waiting and not pr.threads[2].waiting)
check("outdated thread uses originalLine", pr.threads[1].line == 2 and pr.threads[1].outdated)
check("events newest first", pr.events[1].who == "github-actions")
local kinds = {}
for _, e in ipairs(pr.events) do
  kinds[e.kind] = (kinds[e.kind] or 0) + 1
end
check("event kinds", kinds.commit == 1 and kinds.force_push == 1 and kinds.review_requested == 1
  and kinds.review == 1 and kinds.ci_fail == 1 and kinds.comment == 1 and not kinds.ci_ok)

-- stale rollup: everything green after a re-run → not failing
local green = gh.normalize_pr(fixture({ commits = { nodes = { { commit = { statusCheckRollup = { state = "FAILURE",
  contexts = { nodes = { run("lint", "CANCELLED", 1, 9000, 8990), run("lint", "SUCCESS", 2, 5000, 4000) } } } } } } } }))
check("stale FAILURE rollup ignored", not gh.ci_failing(green.pr) and green.pr.ci.passed == 1)
check("ci_ok event", green.pr.events[1].kind == "ci_ok" or vim.iter(green.pr.events):any(function(e) return e.kind == "ci_ok" end))

local merge_status = require("ahoy.sections.pr")._merge_status
check("merge: blocked reason", merge_status(pr):find("changes requested") ~= nil)
check("merge: conflict", merge_status({ mergeable = "CONFLICTING", base = "main" }):find("conflicts with main") ~= nil)
check("merge: clean", merge_status({ merge_state = "CLEAN" }):find("ready to merge") ~= nil)
check("shortstat", select(3, require("ahoy.sections.pr")._parse_shortstat(" 8 files changed, 120 insertions(+), 30 deletions(-)")) == 30)

-- dashboard (PR exists) -------------------------------------------------------
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/src", "p")
vim.fn.writefile({ "one", "two", "three" }, root .. "/src/a.lua")

local fake_ctx
require("ahoy.context").detect = function(cb)
  local ctx = vim.deepcopy(fake_ctx)
  ctx.time = os.time()
  vim.schedule(function()
    cb(ctx)
  end)
end
local calls, vars_seen = 0, nil
gh.graphql = function(_, vars, cb)
  calls = calls + 1
  vars_seen = vars
  vim.defer_fn(function()
    cb(fixture())
  end, 30)
end

fake_ctx = { cwd = root, root = root, kind = "pr", branch = "feat", default_branch = "main", repo = "acme/app",
  git = { dirty = 0, ahead = 0, behind = 0, upstream = "origin/feat" },
  pr = { number = 42, url = "https://github.com/acme/app/pull/42" } }

require("ahoy").setup({ show_on_startup = false, browser = "open" })
vim.o.columns = 170
local ahoy = require("ahoy")
ahoy.open()
local function lines()
  return vim.api.nvim_buf_get_lines(ahoy._state.buf, 0, -1, false)
end
local function text()
  return table.concat(lines(), "\n")
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
vim.wait(5000, settled, 20)
local t = text()
if os.getenv("AHOY_DUMP") then
  print(t)
end
check("one graphql call for pr/threads/activity", calls == 1)
check("query targets PR repo", vars_seen.owner == "acme" and vars_seen.name == "app" and vars_seen.n == 42)
check("hero title", t:find("#42 Make it faster") ~= nil)
check("hero checks", t:find("✗ 1 failing · ● 1 running · ✓ 1/3") ~= nil)
check("hero reviewers", t:find("● alice") and t:find("✗ bob") and t:find("● @core"))
check("hero hides bot reviewer", t:find("cursor") == nil)
check("hero merge", t:find("blocked: changes requested") ~= nil)
check("hero diff", t:find("+120 −30 · 8 files · 5 commits") ~= nil)
check("hero failing check row", t:find("✗ unit") ~= nil)
check("threads card", t:find("Unresolved threads") and t:find("src/a.lua:2") and t:find("bob: why%?"))
check("activity card", t:find("bob requested changes") and t:find("you force%-pushed def5678")
  and t:find("you pushed abc1234") and t:find("CI ✗ unit"))
check("activity hides bots", t:find("Plan output") == nil)
check("footer shows PR", t:find("pr #42") ~= nil)

local function cursor_on(needle)
  for i, l in ipairs(lines()) do
    local col = l:find(needle, 1, true)
    if col then
      vim.api.nvim_win_set_cursor(0, { i, col - 1 })
      return true
    end
  end
end

local actions = require("ahoy.actions")
local logged
local orig_log = actions.log_failed
actions.log_failed = function(ch, repo)
  logged = { ch.run_id, repo }
end
cursor_on("✗ unit")
vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
check("<CR> failing check → log", logged and logged[1] == 3 and logged[2] == "acme/app")
logged = nil
cursor_on("CI ✗ unit")
vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
check("<CR> CI activity → log", logged and logged[1] == 3)
actions.log_failed = orig_log

local opened
vim.ui.open = function(u)
  opened = u
end
cursor_on("src/a.lua:2")
vim.api.nvim_feedkeys("o", "x", false)
check("o thread → browser", opened == "https://t/a")
cursor_on("src/a.lua:2")
vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
check("<CR> thread → file:line", vim.api.nvim_buf_get_name(0) == root .. "/src/a.lua"
  and vim.api.nvim_win_get_cursor(0)[1] == 2)

-- error surfacing in the PR view
ahoy.open()
gh.graphql = function(_, _, cb)
  vim.schedule(function()
    cb(nil, "Could not resolve to a PullRequest")
  end)
end
ahoy.refresh()
vim.wait(3000, settled, 20)
check("pr error surfaced", text():find("✗ Could not resolve") ~= nil)

-- no PR yet (local git) --------------------------------------------------------
local repo = vim.fn.tempname()
vim.fn.mkdir(repo, "p")
local function git(...)
  local r = vim.system(vim.list_extend({ "git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t",
    "-c", "commit.gpgsign=false" }, { ... }), { text = true }):wait()
  assert(r.code == 0, r.stderr)
  return r.stdout
end
git("init", "-q", "-b", "main")
vim.fn.writefile({ "a" }, repo .. "/f.txt")
git("add", ".")
git("commit", "-qm", "base")
git("switch", "-qc", "topic")
vim.fn.writefile({ "a", "b", "c" }, repo .. "/f.txt")
vim.fn.writefile({ "x" }, repo .. "/g.txt")
git("add", ".")
git("commit", "-qm", "add stuff")
git("rm", "-q", "g.txt")
git("commit", "-qm", "remove g")

calls = 0
fake_ctx = { cwd = repo, root = repo, kind = "pr", branch = "topic", default_branch = "main",
  git = { dirty = 0, ahead = 0, behind = 0 } }
ahoy.refresh()
vim.wait(5000, settled, 20)
t = text()
if os.getenv("AHOY_DUMP") then
  print(t)
end
check("no-PR: no graphql", calls == 0)
check("no-PR hero", t:find("⎇ topic  no PR yet") ~= nil)
check("no-PR diffstat", t:find("+2 −0 · 1 file · 2 commits ahead of main") ~= nil)
check("no-PR push hint", t:find("git push %-u origin topic") ~= nil)
check("no-PR create hint", t:find("gh pr create %-%-fill %-%-base main") ~= nil)
check("no-PR commits", t:find("remove g") and t:find("add stuff"))
check("no-PR hides threads/activity", t:find("Unresolved threads") == nil and t:find("Activity") == nil)

local copied
local orig_setreg = vim.fn.setreg
vim.fn.setreg = function(reg, v)
  if reg == "+" then
    copied = v
  end
end
cursor_on("git push -u origin topic")
vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
vim.fn.setreg = orig_setreg
check("<CR> on hint copies command", copied == "git push -u origin topic")

vim.fn.delete(root, "rf")
vim.fn.delete(repo, "rf")
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
  print("ERROR " .. tostring(err))
  failures = failures + 1
end
print(failures == 0 and "ALL PASSED" or (failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)
