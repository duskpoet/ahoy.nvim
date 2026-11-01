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
      ... on CheckRun { name conclusion status detailsUrl checkSuite { workflowRun { databaseId } } }
      ... on StatusContext { context state targetUrl } } } } } } }
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

---Summarize a statusCheckRollup: { state, total, passed, pending, failing = {{name, url, run_id}} }.
function M.norm_ci(roll)
  if type(roll) ~= "table" then
    return nil
  end
  local ci = { state = roll.state, total = 0, passed = 0, pending = 0, failing = {} }
  local seen_runs = {}
  for _, c in ipairs(roll.contexts and roll.contexts.nodes or {}) do
    ci.total = ci.total + 1
    if c.__typename == "CheckRun" then
      if c.status ~= "COMPLETED" then
        ci.pending = ci.pending + 1
      elseif CHECK_OK[c.conclusion] then
        ci.passed = ci.passed + 1
      else
        local run = c.checkSuite and c.checkSuite.workflowRun and c.checkSuite.workflowRun.databaseId
        table.insert(ci.failing, { name = c.name, url = c.detailsUrl, run_id = run, dup = run and seen_runs[run] })
        if run then
          seen_runs[run] = true
        end
      end
    else
      if c.state == "SUCCESS" then
        ci.passed = ci.passed + 1
      elseif c.state == "PENDING" or c.state == "EXPECTED" then
        ci.pending = ci.pending + 1
      else
        table.insert(ci.failing, { name = c.context, url = c.targetUrl })
      end
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
function M.ci_failing(pr)
  return pr.ci ~= nil and (pr.ci.state == "FAILURE" or pr.ci.state == "ERROR" or #pr.ci.failing > 0)
end

function M.ready_to_merge(pr)
  if pr.draft or pr.review ~= "APPROVED" or pr.mergeable ~= "MERGEABLE" then
    return false
  end
  if M.ci_failing(pr) or (pr.ci and pr.ci.state == "PENDING") then
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

-- One request per dashboard refresh, shared by every section (keyed by the ctx table).
local inflight = setmetatable({}, { __mode = "k" })

---Fetch the normalized main-view model. `cb(model, err)`.
function M.main(ctx, cb)
  local e = inflight[ctx]
  if e then
    if e.done then
      return vim.schedule(function()
        cb(e.model, e.err)
      end)
    end
    return table.insert(e.waiters, cb)
  end
  e = { waiters = { cb } }
  inflight[ctx] = e
  M.graphql(M.MAIN_QUERY, search_vars(), function(data, err)
    local model
    if data then
      local ok, res = pcall(M.normalize, data)
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

---Short reference: "#12" in the current repo, "name#12" elsewhere.
function M.ref(pr, repo)
  if pr.repo and pr.repo ~= repo then
    return (pr.repo:match("/(.+)$") or pr.repo) .. "#" .. pr.number
  end
  return "#" .. pr.number
end

return M
