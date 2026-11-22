-- Offline stand-ins for `gh` and `curl` used by the demo recording (see demo/README.md).
-- Run as `nvim -l demo/fake.lua gh|curl <args...>`. Every timestamp is relative to now, so the
-- dashboard always shows "12m ago", a meeting in progress, etc. No network access.
local tool = table.remove(arg, 1)
local now = os.time()
local ME, REPO = "sam", "acme/rocket"
local URL = "https://github.com/" .. REPO

local function out(s)
  io.stdout:write(s)
end
local function die(msg, code)
  io.stderr:write(msg .. "\n")
  os.exit(code or 1)
end
local function json(v)
  out(vim.json.encode(v))
end
local function iso(t)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", t)
end
local function ago(min)
  return iso(now - min * 60)
end
local function nap(s) -- look like a network round-trip
  vim.uv.sleep(math.floor(s * 1000))
end
local function user(login)
  return { __typename = "User", login = login }
end

-- curl: the calendar feed ------------------------------------------------------------------

local function ics()
  -- Anchored at setup time so agenda times don't shift mid-take when a 5-minute boundary passes.
  local t0 = tonumber(vim.env.AHOY_DEMO_T0) or now
  local base = t0 - t0 % 300
  local function dt(t)
    return os.date("!%Y%m%dT%H%M%SZ", t)
  end
  local evs = {
    { "Inbox & PR triage", base - 120 * 60, base - 90 * 60 },
    { "Standup", base - 15 * 60, base + 10 * 60, "https://meet.google.com/abc-defg-hij" },
    { "Design review: upload retries", base + 60 * 60, base + 105 * 60, "https://meet.google.com/xyz-uvwx-rst" },
    { "1:1 Mara / Sam", base + 180 * 60, base + 210 * 60 },
    { "Sprint planning", base + 240 * 60, base + 300 * 60, "https://meet.google.com/pln-sprt-qqq" },
  }
  local l = { "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//ahoy demo//EN", "X-WR-CALNAME:sam@example.com" }
  for i, e in ipairs(evs) do
    vim.list_extend(l, {
      "BEGIN:VEVENT",
      "UID:demo-" .. i .. "@example.com",
      "DTSTAMP:" .. dt(now),
      "DTSTART:" .. dt(e[2]),
      "DTEND:" .. dt(e[3]),
      "SUMMARY:" .. e[1],
      "ATTENDEE;PARTSTAT=ACCEPTED:mailto:sam@example.com",
    })
    if e[4] then
      l[#l + 1] = "X-GOOGLE-CONFERENCE:" .. e[4]
    end
    l[#l + 1] = "END:VEVENT"
  end
  l[#l + 1] = "END:VCALENDAR"
  return table.concat(l, "\r\n") .. "\r\n"
end

if tool == "curl" then
  io.stdin:read("*a") -- the -K config with the (fake) URL
  nap(0.5)
  out(ics())
  os.exit(0)
end

if tool ~= "gh" then
  die("fake.lua: unknown tool " .. tostring(tool))
end

-- gh fixtures ------------------------------------------------------------------------------

local function check(name, conclusion, min, run)
  return {
    __typename = "CheckRun",
    name = name,
    status = conclusion and "COMPLETED" or "IN_PROGRESS",
    conclusion = conclusion,
    detailsUrl = URL .. "/actions/runs/" .. run,
    startedAt = ago(min + 3),
    completedAt = conclusion and ago(min) or vim.NIL,
    checkSuite = { workflowRun = { databaseId = run } },
  }
end
local function rollup(state, checks)
  return { nodes = { { commit = { oid = "4f2c9e1", committedDate = ago(14),
    statusCheckRollup = { state = state, contexts = { nodes = checks } } } } } }
end
local function comment(who, min, body)
  return { author = user(who), createdAt = ago(min), url = URL .. "/pull/0#c" .. min, bodyText = body }
end

local function main_view()
  local pr39 = {
    number = 39, title = "Stream uploads in 8 MiB chunks", url = URL .. "/pull/39", isDraft = false,
    updatedAt = ago(25), reviewDecision = "REVIEW_REQUIRED", mergeable = "MERGEABLE", mergeStateStatus = "BLOCKED",
    baseRefName = "main", headRefName = "sam/chunked-upload", author = user(ME), repository = { nameWithOwner = REPO },
    commits = rollup("FAILURE", {
      check("lint", "SUCCESS", 30, 8811), check("build", "SUCCESS", 29, 8811), check("unit", "FAILURE", 27, 8812),
    }),
    reviewThreads = { nodes = {
      { isResolved = false, isOutdated = false, path = "src/rocket/upload.py", line = 31,
        comments = { nodes = { comment("theo", 40, "Should this respect the server's max part size?") } } },
      { isResolved = false, isOutdated = false, path = "src/rocket/upload.py", line = 18,
        comments = { nodes = { comment("theo", 38, "nit: chunk_size could default from config") } } },
    } },
    timelineItems = { nodes = {
      { __typename = "PullRequestCommit", url = URL .. "/pull/39/commits/a1",
        commit = { committedDate = ago(70), messageHeadline = "Stream file in chunks", author = { user = user(ME) } } },
      { __typename = "IssueComment", author = user("theo"), createdAt = ago(35), url = URL .. "/pull/39#c1",
        bodyText = "Tried it against staging: a 2 GB file went through fine" },
    } },
  }
  local pr37 = {
    number = 37, title = "Run CI on Python 3.13", url = URL .. "/pull/37", isDraft = false,
    updatedAt = ago(130), reviewDecision = "APPROVED", mergeable = "MERGEABLE", mergeStateStatus = "CLEAN",
    baseRefName = "main", headRefName = "sam/py313", author = user(ME), repository = { nameWithOwner = REPO },
    commits = rollup("SUCCESS", {
      check("lint", "SUCCESS", 150, 8790), check("build", "SUCCESS", 149, 8790), check("unit", "SUCCESS", 147, 8790),
    }),
    reviewThreads = { nodes = {} },
    timelineItems = { nodes = {
      { __typename = "PullRequestReview", author = user("mara"), submittedAt = ago(130), state = "APPROVED",
        url = URL .. "/pull/37#r1", bodyText = "LGTM, ship it" },
    } },
  }
  return {
    viewer = { login = ME },
    mine = { nodes = { pr39, pr37 } },
    requested = { nodes = {
      { number = 42, title = "Retry flaky uploads with exponential backoff", url = URL .. "/pull/42", isDraft = false,
        updatedAt = ago(12), baseRefName = "main", headRefName = "mara/retry-backoff", author = user("mara"),
        repository = { nameWithOwner = REPO } },
    } },
    mentions = { nodes = {
      { __typename = "Issue", number = 311, title = "Staging bucket quota alerts are too noisy",
        url = "https://github.com/acme/infra/issues/311", updatedAt = ago(190), author = user("priya"),
        repository = { nameWithOwner = "acme/infra" } },
    } },
  }
end

local function thread(path, line, root, last, count)
  last = last or root
  return { isResolved = false, isOutdated = false, path = path, line = line,
    comments = { totalCount = count or 1, nodes = { root } }, last = { nodes = { last } } }
end

local function pr_view()
  local function commit(min, msg)
    return { __typename = "PullRequestCommit", url = URL .. "/pull/42/commits/" .. min,
      commit = { abbreviatedOid = ("%07x"):format(min * 7919), committedDate = ago(min), messageHeadline = msg,
        author = { user = user("mara") } } }
  end
  return {
    viewer = { login = ME },
    repository = { pullRequest = {
      number = 42, title = "Retry flaky uploads with exponential backoff", url = URL .. "/pull/42", state = "OPEN",
      isDraft = false, createdAt = ago(27 * 60), updatedAt = ago(12), baseRefName = "main",
      headRefName = "mara/retry-backoff", additions = 74, deletions = 12, changedFiles = 3,
      reviewDecision = "REVIEW_REQUIRED", mergeable = "MERGEABLE", mergeStateStatus = "BLOCKED",
      author = user("mara"), repository = { nameWithOwner = REPO },
      allCommits = { totalCount = 4 },
      commits = rollup("FAILURE", {
        check("lint", "SUCCESS", 12, 9001), check("build", "SUCCESS", 11, 9001), check("unit", "FAILURE", 9, 9001),
        check("e2e", nil, 0, 9002),
      }),
      latestReviews = { nodes = { { author = user("theo"), state = "COMMENTED", submittedAt = ago(180) } } },
      reviewRequests = { nodes = {
        { requestedReviewer = { __typename = "User", login = ME } },
        { requestedReviewer = { __typename = "Team", name = "platform" } },
      } },
      reviewThreads = { nodes = {
        thread("src/rocket/retry.py", 24, comment("theo", 180, "Cap the jitter: at attempt 8 this sleeps for minutes"),
          comment("mara", 20, "Good catch, capped at max_delay"), 2),
        thread("src/rocket/retry.py", 34, comment("theo", 178, "Should a 429 honour Retry-After instead of backing off?")),
        thread("tests/test_retry.py", 21, comment("theo", 175, "Random jitter in a test; seed it or inject the RNG?")),
      } },
      timelineItems = { nodes = {
        { __typename = "ReviewRequestedEvent", actor = user("mara"), createdAt = ago(27 * 60),
          requestedReviewer = { login = ME } },
        commit(27 * 60 + 5, "Add exponential backoff to the uploader"),
        commit(26 * 60, "Retry on 5xx and connection resets"),
        { __typename = "PullRequestReview", author = user("theo"), submittedAt = ago(180), state = "COMMENTED",
          url = URL .. "/pull/42#r1", bodyText = "A few questions on the jitter maths" },
        commit(14, "Cap jitter at max_delay"),
        { __typename = "IssueComment", author = user("mara"), createdAt = ago(13), url = URL .. "/pull/42#c2",
          bodyText = "Addressed the cap; Retry-After next. @sam could you take a look?" },
      } },
    } },
  }
end

local FAILED_LOG = [[
unit	Run pytest	%s ============================= test session starts ==============================
unit	Run pytest	%s platform linux -- Python 3.12.7, pytest-8.3.3, pluggy-1.5.0
unit	Run pytest	%s collected 9 items
unit	Run pytest	%s
unit	Run pytest	%s tests/test_retry.py ....F                                              [ 55%%]
unit	Run pytest	%s tests/test_upload.py ....                                              [100%%]
unit	Run pytest	%s
unit	Run pytest	%s =================================== FAILURES ===================================
unit	Run pytest	%s __________________________ test_honours_retry_after ___________________________
unit	Run pytest	%s
unit	Run pytest	%s     def test_honours_retry_after():
unit	Run pytest	%s         sleeps = []
unit	Run pytest	%s         retry(flaky(TooManyRequests(retry_after=3.0)), sleep=sleeps.append)
unit	Run pytest	%s >       assert sleeps == [3.0]
unit	Run pytest	%s E       assert [0.71] == [3.0]
unit	Run pytest	%s E         At index 0 diff: 0.71 != 3.0
unit	Run pytest	%s
unit	Run pytest	%s tests/test_retry.py:39: AssertionError
unit	Run pytest	%s =========================== short test summary info ============================
unit	Run pytest	%s FAILED tests/test_retry.py::test_honours_retry_after - assert [0.71] == [3.0]
unit	Run pytest	%s ========================= 1 failed, 8 passed in 0.42s ==========================
unit	Run pytest	%s ##[error]Process completed with exit code 1.]]

local function git(...)
  local r = vim.system({ "git", ... }, { text = true }):wait()
  return r.code, vim.trim(r.stdout or ""), vim.trim(r.stderr or "")
end

local sub = table.concat({ arg[1] or "", arg[2] or "" }, " ")
if sub == "api graphql" then
  local q = ""
  for i = 3, #arg do
    q = arg[i]:match("^query=(.*)") or q
  end
  nap(0.9)
  json({ data = q:find("pullRequest%(") and pr_view() or main_view() })
elseif sub == "pr view" then
  local _, branch = git("branch", "--show-current")
  if branch ~= "mara/retry-backoff" then
    die(('no pull requests found for branch "%s"'):format(branch))
  end
  json({ number = 42, state = "OPEN", url = URL .. "/pull/42", title = "Retry flaky uploads with exponential backoff",
    baseRefName = "main" })
elseif sub == "pr checkout" then
  nap(0.6)
  local code, _, err = git("checkout", "-q", "-B", "mara/retry-backoff", "--track", "origin/mara/retry-backoff")
  if code ~= 0 then
    die(err)
  end
  io.stderr:write("Switched to branch 'mara/retry-backoff'\n")
elseif sub == "run view" then
  nap(0.7)
  local stamps = {}
  for i = 1, 22 do
    stamps[i] = os.date("!%Y-%m-%dT%H:%M:%S", now - 9 * 60 + math.floor(i / 4)) .. ".0000000Z"
  end
  out(FAILED_LOG:format(unpack(stamps)) .. "\n")
else
  die("fake gh: unsupported: gh " .. table.concat(arg, " "))
end
