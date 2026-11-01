-- GitHub via the `gh` CLI: async GraphQL + the shared main-view query.
-- Read-only: nothing here writes to a remote.
local util = require("ahoy.util")

local M = {}

local function gcfg()
  local ok, ahoy = pcall(require, "ahoy")
  local c = ok and ahoy.config and ahoy.config.github
  return c or require("ahoy.config").defaults.github
end

---First error message from a GraphQL response body, if any.
local function gql_error(body)
  if type(body) == "table" and type(body.errors) == "table" and body.errors[1] then
    return body.errors[1].message or vim.inspect(body.errors[1])
  end
end

---Run a GraphQL query. `cb(data, err)` on the main loop.
---String vars are passed with -f, numbers/booleans with -F.
function M.graphql(query, vars, cb)
  if not util.has("gh") then
    return vim.schedule(function()
      cb(nil, "gh CLI not found (https://cli.github.com)")
    end)
  end
  local cmd = { "gh", "api", "graphql", "-f", "query=" .. query }
  for k, v in pairs(vars or {}) do
    vim.list_extend(cmd, { type(v) == "string" and "-f" or "-F", k .. "=" .. tostring(v) })
  end
  util.run(cmd, { env = { GH_PROMPT_DISABLED = "1", NO_COLOR = "1" }, timeout = 25000 }, function(r)
    local ok, body = pcall(vim.json.decode, r.stdout or "", { luanil = { object = true, array = true } })
    if not ok then
      body = nil
    end
    local data = type(body) == "table" and body.data or nil
    if r.code ~= 0 or not data then
      local msg = gql_error(body) or vim.trim(r.stderr or "")
      if msg == "" then
        msg = ("gh exited with %d"):format(r.code or -1)
      end
      if r.code == 124 or (r.signal and r.signal ~= 0) then
        msg = "gh timed out"
      end
      return cb(nil, msg)
    end
    cb(data, nil)
  end)
end

-- Main-view query -------------------------------------------------------------

M.MAIN_QUERY = [[
query($mine: String!, $req: String!, $men: String!, $n: Int!) {
  viewer { login }
  mine: search(query: $mine, type: ISSUE, first: $n) { nodes { ... on PullRequest {
    number title url isDraft updatedAt reviewDecision mergeable mergeStateStatus baseRefName headRefName
    author { login }
    repository { nameWithOwner }
    commits(last: 1) { nodes { commit { statusCheckRollup { state contexts(first: 100) { nodes {
      __typename
      ... on CheckRun { name conclusion status detailsUrl startedAt completedAt checkSuite { workflowRun { databaseId } } }
      ... on StatusContext { context state targetUrl createdAt } } } } } } }
    reviewThreads(first: 100) { nodes { isResolved isOutdated path line originalLine
      comments(last: 1) { nodes { author { __typename login } createdAt url bodyText } } } }
    timelineItems(last: 8, itemTypes: [ISSUE_COMMENT, PULL_REQUEST_REVIEW, PULL_REQUEST_COMMIT]) { nodes {
      __typename
      ... on IssueComment { author { __typename login } createdAt url bodyText }
      ... on PullRequestReview { author { __typename login } submittedAt state url bodyText }
      ... on PullRequestCommit { url commit { committedDate messageHeadline author { user { login } name } } } } }
  } } }
  requested: search(query: $req, type: ISSUE, first: $n) { nodes { ... on PullRequest {
    number title url isDraft updatedAt baseRefName headRefName
    author { login } repository { nameWithOwner } } } }
  mentions: search(query: $men, type: ISSUE, first: $n) { nodes {
    __typename
    ... on PullRequest { number title url updatedAt author { login } repository { nameWithOwner } }
    ... on Issue { number title url updatedAt author { login } repository { nameWithOwner } } } }
}]]

local CHECK_OK = { SUCCESS = true, NEUTRAL = true, SKIPPED = true }

local function login_of(a)
  return type(a) == "table" and a.login or nil
end

local function is_bot(a)
  return type(a) == "table" and (a.__typename == "Bot" or (a.login or ""):match("%[bot%]$") ~= nil)
end

local function first_line(s, n)
  s = (s or ""):gsub("\r", ""):match("^%s*([^\n]*)") or ""
  return n and #s > n and s:sub(1, n) or s
end

---Summarize a statusCheckRollup:
---{ state, total, passed, pending, failing = {check...}, checks = {check...} }
---check = { name, status = "ok"|"pending"|"fail", conclusion?, url, run_id?, at? }.
---Re-runs of a check with the same name collapse to the most recently started one.
function M.norm_ci(roll)
  if type(roll) ~= "table" then
    return nil
  end
  local ci = { state = roll.state, total = 0, passed = 0, pending = 0, failing = {}, checks = {} }
  local by_name = {}
  for _, c in ipairs(roll.contexts and roll.contexts.nodes or {}) do
    local ch
    if c.__typename == "CheckRun" then
      ch = {
        name = c.name,
        url = c.detailsUrl,
        run_id = c.checkSuite and c.checkSuite.workflowRun and c.checkSuite.workflowRun.databaseId,
        conclusion = c.conclusion,
        started = util.iso_to_epoch(c.startedAt),
        at = util.iso_to_epoch(c.completedAt),
      }
      ch.status = c.status ~= "COMPLETED" and "pending" or CHECK_OK[c.conclusion] and "ok" or "fail"
    else
      ch = { name = c.context, url = c.targetUrl, conclusion = c.state, at = util.iso_to_epoch(c.createdAt) }
      ch.started = ch.at
      ch.status = c.state == "SUCCESS" and "ok" or (c.state == "PENDING" or c.state == "EXPECTED") and "pending"
        or "fail"
    end
    local prev = ch.name and by_name[ch.name]
    if not prev then
      ci.checks[#ci.checks + 1] = ch
      if ch.name then
        by_name[ch.name] = #ci.checks
      end
    elseif (ch.started or 0) >= (ci.checks[prev].started or 0) then
      ci.checks[prev] = ch
    end
  end
  for _, ch in ipairs(ci.checks) do
    ci.total = ci.total + 1
    if ch.status == "ok" then
      ci.passed = ci.passed + 1
    elseif ch.status == "pending" then
      ci.pending = ci.pending + 1
    else
      ci.failing[#ci.failing + 1] = ch
    end
  end
  return ci
end

local function norm_event(n, pr)
  local t = n.__typename
  if t == "IssueComment" then
    return { kind = "comment", who = login_of(n.author), bot = is_bot(n.author), at = util.iso_to_epoch(n.createdAt),
      url = n.url, text = first_line(n.bodyText, 200), pr = pr }
  elseif t == "PullRequestReview" then
    return { kind = "review", state = n.state, who = login_of(n.author), bot = is_bot(n.author),
      at = util.iso_to_epoch(n.submittedAt),
      url = n.url, text = first_line(n.bodyText, 200), pr = pr }
  elseif t == "PullRequestCommit" and n.commit then
    local a = n.commit.author or {}
    return { kind = "commit", who = a.user and a.user.login or a.name, at = util.iso_to_epoch(n.commit.committedDate),
      url = n.url, text = n.commit.messageHeadline, pr = pr }
  end
end

local function norm_pr(n, login)
  if type(n) ~= "table" or not n.number then
    return nil
  end
  local pr = {
    repo = n.repository and n.repository.nameWithOwner,
    number = n.number,
    title = n.title or "",
    url = n.url,
    draft = n.isDraft,
    updated = util.iso_to_epoch(n.updatedAt),
    author = login_of(n.author),
    base = n.baseRefName,
    head = n.headRefName,
    review = n.reviewDecision,
    mergeable = n.mergeable,
    merge_state = n.mergeStateStatus,
    kind = n.__typename == "Issue" and "issue" or "pr",
  }
  local c = n.commits and n.commits.nodes and n.commits.nodes[1]
  pr.ci = M.norm_ci(c and c.commit and c.commit.statusCheckRollup)

  if n.reviewThreads then
    pr.threads, pr.waiting_threads = {}, 0
    for _, th in ipairs(n.reviewThreads.nodes or {}) do
      if not th.isResolved then
        local last = th.comments and th.comments.nodes and th.comments.nodes[1] or {}
        local t = {
          path = th.path,
          line = th.line or th.originalLine,
          outdated = th.isOutdated,
          who = login_of(last.author),
          bot = is_bot(last.author),
          at = util.iso_to_epoch(last.createdAt),
          url = last.url,
          text = first_line(last.bodyText, 200),
        }
        t.waiting = t.who ~= login
        if t.waiting then
          pr.waiting_threads = pr.waiting_threads + 1
        end
        table.insert(pr.threads, t)
      end
    end
  end

  if n.timelineItems then
    pr.events = {}
    for _, e in ipairs(n.timelineItems.nodes or {}) do
      local ev = norm_event(e, pr)
      if ev then
        table.insert(pr.events, ev)
      end
    end
  end
  return pr
end

local function nodes(s)
  return type(s) == "table" and s.nodes or {}
end

---Status of one of my PRs, used by several sections.
---Judged from the de-duplicated checks: GitHub's rollup state stays FAILURE when a check failed
---and was later re-run green. The rollup is only used when there are no individual checks.
function M.ci_failing(pr)
  local ci = pr.ci
  if not ci then
    return false
  end
  if ci.total > 0 then
    return #ci.failing > 0
  end
  return ci.state == "FAILURE" or ci.state == "ERROR"
end

function M.ci_pending(pr)
  local ci = pr.ci
  if not ci then
    return false
  end
  if ci.total > 0 then
    return ci.pending > 0
  end
  return ci.state == "PENDING" or ci.state == "EXPECTED"
end

function M.ready_to_merge(pr)
  if pr.draft or pr.review ~= "APPROVED" or pr.mergeable ~= "MERGEABLE" then
    return false
  end
  if M.ci_failing(pr) or M.ci_pending(pr) then
    return false
  end
  return pr.merge_state ~= "BLOCKED" and pr.merge_state ~= "DIRTY" and pr.merge_state ~= "BEHIND"
end

---Turn the raw main-query response into
---{ login, mine = {pr...}, requested = {pr...}, mentions = {pr|issue...}, events = {ev...} }
function M.normalize(data)
  local login = data.viewer and data.viewer.login
  local m = { login = login, mine = {}, requested = {}, mentions = {}, events = {} }
  for _, n in ipairs(nodes(data.mine)) do
    local pr = norm_pr(n, login)
    if pr then
      table.insert(m.mine, pr)
      for _, ev in ipairs(pr.events or {}) do
        if ev.who ~= login then
          table.insert(m.events, ev)
        end
      end
      for _, th in ipairs(pr.threads or {}) do
        if th.waiting then
          table.insert(m.events, { kind = "thread", who = th.who, bot = th.bot, at = th.at, url = th.url, text = th.text,
            path = th.path, line = th.line, pr = pr })
        end
      end
    end
  end
  for _, n in ipairs(nodes(data.requested)) do
    table.insert(m.requested, norm_pr(n, login))
  end
  for _, n in ipairs(nodes(data.mentions)) do
    table.insert(m.mentions, norm_pr(n, login))
  end
  table.sort(m.events, function(a, b)
    return (a.at or 0) > (b.at or 0)
  end)
  return m
end

M.cfg = gcfg
M.REVIEW_SEARCH = "is:pr is:open review-requested:@me archived:false sort:updated-desc"

local function search_vars()
  local c = gcfg()
  local since = os.date("!%Y-%m-%d", os.time() - (c.mentions_days or 14) * 86400)
  return {
    mine = "is:pr is:open author:@me archived:false sort:updated-desc",
    req = M.REVIEW_SEARCH,
    men = ("is:open mentions:@me -author:@me archived:false updated:>=%s sort:updated-desc"):format(since),
    n = c.limit or 30,
  }
end

-- One request per (dashboard refresh, query), shared by every section. Keyed by the ctx table,
-- which is recreated on each refresh.
local inflight = setmetatable({}, { __mode = "k" })

---Run `query` once per ctx under `key`, normalize with `norm(data)`, fan out `cb(model, err)`.
local function shared(ctx, key, query, vars, norm, cb)
  inflight[ctx] = inflight[ctx] or {}
  local e = inflight[ctx][key]
  if e then
    if e.done then
      return vim.schedule(function()
        cb(e.model, e.err)
      end)
    end
    return table.insert(e.waiters, cb)
  end
  e = { waiters = { cb } }
  inflight[ctx][key] = e
  M.graphql(query, vars, function(data, err)
    local model
    if data then
      local ok, res = pcall(norm, data)
      if ok then
        model = res
      else
        err = "normalize: " .. tostring(res)
      end
    end
    e.done, e.model, e.err = true, model, err
    for _, w in ipairs(e.waiters) do
      w(model, err)
    end
  end)
end

---Fetch the normalized main-view model. `cb(model, err)`.
function M.main(ctx, cb)
  shared(ctx, "main", M.MAIN_QUERY, search_vars(), M.normalize, cb)
end

-- PR-view query ---------------------------------------------------------------

M.PR_QUERY = [[
query($owner: String!, $name: String!, $n: Int!) {
  viewer { login }
  repository(owner: $owner, name: $name) { pullRequest(number: $n) {
    number title url state isDraft createdAt updatedAt baseRefName headRefName additions deletions changedFiles
    reviewDecision mergeable mergeStateStatus author { login } repository { nameWithOwner }
    allCommits: commits { totalCount }
    commits(last: 1) { nodes { commit { oid committedDate statusCheckRollup { state contexts(first: 100) { nodes {
      __typename
      ... on CheckRun { name conclusion status detailsUrl startedAt completedAt checkSuite { workflowRun { databaseId } } }
      ... on StatusContext { context state targetUrl createdAt } } } } } } }
    latestReviews(first: 30) { nodes { author { __typename login } state submittedAt } }
    reviewRequests(first: 30) { nodes { requestedReviewer { __typename
      ... on User { login } ... on Team { name } ... on Bot { login } ... on Mannequin { login } } } }
    reviewThreads(first: 100) { nodes { isResolved isOutdated path line originalLine
      comments(first: 1) { totalCount nodes { author { __typename login } bodyText createdAt url } }
      last: comments(last: 1) { nodes { author { __typename login } createdAt bodyText url } } } }
    timelineItems(last: 40, itemTypes: [ISSUE_COMMENT, PULL_REQUEST_REVIEW, PULL_REQUEST_COMMIT,
        HEAD_REF_FORCE_PUSHED_EVENT, REVIEW_REQUESTED_EVENT, READY_FOR_REVIEW_EVENT, CONVERT_TO_DRAFT_EVENT]) { nodes {
      __typename
      ... on IssueComment { author { __typename login } createdAt url bodyText }
      ... on PullRequestReview { author { __typename login } submittedAt state url bodyText }
      ... on PullRequestCommit { url commit { abbreviatedOid committedDate messageHeadline author { user { login } name } } }
      ... on HeadRefForcePushedEvent { actor { __typename login } createdAt afterCommit { abbreviatedOid } }
      ... on ReviewRequestedEvent { actor { __typename login } createdAt
        requestedReviewer { ... on User { login } ... on Team { name } ... on Bot { login } } }
      ... on ReadyForReviewEvent { actor { __typename login } createdAt }
      ... on ConvertToDraftEvent { actor { __typename login } createdAt } } }
  } }
}]]

local function reviewer_name(r)
  return type(r) == "table" and (r.login or (r.name and ("@" .. r.name))) or nil
end

local function norm_timeline(n, login)
  local t = n.__typename
  local ev
  if t == "IssueComment" or t == "PullRequestReview" or t == "PullRequestCommit" then
    ev = norm_event(n)
    if ev and ev.kind == "commit" then
      ev.oid = n.commit.abbreviatedOid
    end
  elseif t == "HeadRefForcePushedEvent" then
    ev = { kind = "force_push", who = login_of(n.actor), bot = is_bot(n.actor), at = util.iso_to_epoch(n.createdAt),
      oid = n.afterCommit and n.afterCommit.abbreviatedOid }
  elseif t == "ReviewRequestedEvent" then
    ev = { kind = "review_requested", who = login_of(n.actor), bot = is_bot(n.actor),
      at = util.iso_to_epoch(n.createdAt), text = reviewer_name(n.requestedReviewer) }
  elseif t == "ReadyForReviewEvent" then
    ev = { kind = "ready", who = login_of(n.actor), bot = is_bot(n.actor), at = util.iso_to_epoch(n.createdAt) }
  elseif t == "ConvertToDraftEvent" then
    ev = { kind = "draft", who = login_of(n.actor), bot = is_bot(n.actor), at = util.iso_to_epoch(n.createdAt) }
  end
  if ev then
    ev.me = ev.who ~= nil and ev.who == login
  end
  return ev
end

---Normalize the PR-view response:
---{ login, pr = { ...norm_pr fields, state, created, additions, deletions, files, commits, last_commit,
---  reviewers = {{who, state, at, bot}}, threads = {thread...}, events = {ev...} } }
function M.normalize_pr(data)
  local login = data.viewer and data.viewer.login
  local n = data.repository and data.repository.pullRequest
  if not n then
    error("pull request not found")
  end
  local pr = norm_pr(n, login)
  pr.state = n.state
  pr.created = util.iso_to_epoch(n.createdAt)
  pr.additions, pr.deletions, pr.files = n.additions or 0, n.deletions or 0, n.changedFiles or 0
  pr.commits = n.allCommits and n.allCommits.totalCount or 0
  local c = n.commits and n.commits.nodes and n.commits.nodes[1]
  pr.last_commit = c and c.commit and util.iso_to_epoch(c.commit.committedDate)

  -- reviewers: latest review per person, overridden by a pending (re-)request
  local reviewers, idx = {}, {}
  for _, r in ipairs(nodes(n.latestReviews)) do
    local who = login_of(r.author)
    if who and who ~= pr.author then
      reviewers[#reviewers + 1] = { who = who, state = r.state, at = util.iso_to_epoch(r.submittedAt),
        bot = is_bot(r.author) }
      idx[who] = #reviewers
    end
  end
  for _, rr in ipairs(nodes(n.reviewRequests)) do
    local r = rr.requestedReviewer
    local who = reviewer_name(r)
    if who then
      local entry = { who = who, state = "PENDING", team = r.__typename == "Team", bot = r.__typename == "Bot" }
      if idx[who] then
        entry.was = reviewers[idx[who]].state
        reviewers[idx[who]] = entry
      else
        reviewers[#reviewers + 1] = entry
        idx[who] = #reviewers
      end
    end
  end
  pr.reviewers = reviewers

  -- threads: unresolved, with root comment and reply count
  pr.threads = {}
  for _, th in ipairs(nodes(n.reviewThreads)) do
    if not th.isResolved then
      local root = th.comments and th.comments.nodes and th.comments.nodes[1] or {}
      local last = th.last and th.last.nodes and th.last.nodes[1] or root
      local t = {
        path = th.path,
        line = th.line or th.originalLine,
        outdated = th.isOutdated,
        who = login_of(root.author),
        text = first_line(root.bodyText, 200),
        url = root.url,
        count = th.comments and th.comments.totalCount or 1,
        last_who = login_of(last.author),
        at = util.iso_to_epoch(last.createdAt),
      }
      t.waiting = t.last_who ~= login
      pr.threads[#pr.threads + 1] = t
    end
  end
  table.sort(pr.threads, function(a, b)
    if (a.path or "") ~= (b.path or "") then
      return (a.path or "") < (b.path or "")
    end
    return (a.line or 0) < (b.line or 0)
  end)

  -- events: timeline + finished CI on the head commit
  local evs = {}
  for _, e in ipairs(nodes(n.timelineItems)) do
    local ev = norm_timeline(e, login)
    if ev then
      ev.url = ev.url or pr.url
      evs[#evs + 1] = ev
    end
  end
  if pr.ci then
    local last_ok
    for _, ch in ipairs(pr.ci.checks) do
      if ch.status == "fail" then
        evs[#evs + 1] = { kind = "ci_fail", text = ch.name, at = ch.at, url = ch.url, check = ch }
      elseif ch.status == "ok" and (not last_ok or (ch.at or 0) > (last_ok or 0)) then
        last_ok = ch.at
      end
    end
    if pr.ci.pending == 0 and #pr.ci.failing == 0 and pr.ci.total > 0 then
      evs[#evs + 1] = { kind = "ci_ok", text = ("%d checks passed"):format(pr.ci.total), at = last_ok, url = pr.url }
    end
  end
  table.sort(evs, function(a, b)
    return (a.at or 0) > (b.at or 0)
  end)
  pr.events = evs
  return { login = login, pr = pr }
end

---owner, name of the PR's base repo (from its URL, so forks work), else ctx.repo.
local function pr_repo(ctx)
  local owner, name = (ctx.pr and ctx.pr.url or ""):match("^https?://[^/]+/([^/]+)/([^/]+)/pull/%d+")
  if not owner and ctx.repo then
    owner, name = ctx.repo:match("^([^/]+)/(.+)$")
  end
  return owner, name
end

---Fetch the normalized PR-view model for ctx.pr. `cb(model, err)`.
function M.pr(ctx, cb)
  if not ctx.pr then
    return vim.schedule(function()
      cb(nil, "no PR for this branch")
    end)
  end
  local owner, name = pr_repo(ctx)
  if not owner then
    return vim.schedule(function()
      cb(nil, "can't tell which GitHub repo this is (no origin remote?)")
    end)
  end
  shared(ctx, "pr", M.PR_QUERY, { owner = owner, name = name, n = ctx.pr.number }, M.normalize_pr, cb)
end

---Short reference: "#12" in the current repo, "name#12" elsewhere.
function M.ref(pr, repo)
  if pr.repo and pr.repo ~= repo then
    return (pr.repo:match("/(.+)$") or pr.repo) .. "#" .. pr.number
  end
  return "#" .. pr.number
end

return M
