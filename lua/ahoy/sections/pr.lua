-- The PR on this branch: CI x/y, per-reviewer state, mergeability, diffstat, timeline, failing checks.
-- Without an open PR: diffstat vs base, unpushed state, and the commands to push / create one.
local gh = require("ahoy.gh")
local ui = require("ahoy.ghui")
local util = require("ahoy.util")
local actions = require("ahoy.actions")

local LW = 8 -- label column

local function label(s)
  return { ui.pad(s, LW), "AhoyDim" }
end

local function plural(n, s)
  return n .. " " .. s .. (n == 1 and "" or "s")
end

-- Local (no PR) ----------------------------------------------------------------

---" 8 files changed, 120 insertions(+), 30 deletions(-)" → files, ins, del
local function parse_shortstat(s)
  s = s or ""
  return tonumber(s:match("(%d+) files? changed")) or 0, tonumber(s:match("(%d+) insertions?")) or 0,
    tonumber(s:match("(%d+) deletions?")) or 0
end

local function fetch_local(ctx, done)
  local base = ctx.default_branch or "main"
  local d = { mode = "local", branch = ctx.branch, base = base, upstream = ctx.git and ctx.git.upstream,
    unpushed = ctx.git and ctx.git.ahead or 0, commits = {}, now = os.time() }
  local function git(args, cb)
    util.run(vim.list_extend({ "git" }, args), { cwd = ctx.root }, cb)
  end
  git({ "rev-parse", "--verify", "--quiet", "origin/" .. base }, function(r)
    d.base_ref = r.code == 0 and ("origin/" .. base) or base
    local pending = 3
    local function step()
      pending = pending - 1
      if pending == 0 then
        done(d)
      end
    end
    git({ "rev-list", "--count", d.base_ref .. "..HEAD" }, function(c)
      d.ahead = c.code == 0 and tonumber(vim.trim(c.stdout)) or nil
      step()
    end)
    git({ "diff", "--shortstat", d.base_ref .. "...HEAD" }, function(s)
      d.files, d.ins, d.del = parse_shortstat(s.code == 0 and s.stdout or "")
      step()
    end)
    git({ "log", "-n", "6", "--format=%h%x09%ct%x09%s", d.base_ref .. "..HEAD" }, function(l)
      for line in (l.code == 0 and l.stdout or ""):gmatch("[^\n]+") do
        local h, t, s = line:match("^(%S+)\t(%d+)\t(.*)$")
        if h then
          d.commits[#d.commits + 1] = { oid = h, at = tonumber(t), subject = s }
        end
      end
      step()
    end)
  end)
end

local function copy_row(cmd)
  return actions.row(nil, function()
    actions.copy(cmd)
  end)
end

local function render_local(d, width)
  local b = ui.builder(width)
  b:add({ { "⎇ " .. (d.branch or "?") .. "  ", "AhoyBranch" }, { "no PR yet", "AhoyWarn" } }, "base " .. d.base_ref)
  if d.ahead == 0 then
    b:add({ label("diff"), { "no commits ahead of " .. d.base_ref, "AhoyDim" } })
  else
    b:add({
      label("diff"),
      { "+" .. (d.ins or 0), "AhoyOk" },
      { " −" .. (d.del or 0), "AhoyError" },
      { " · " .. plural(d.files or 0, "file") .. " · " .. plural(d.ahead or 0, "commit") .. " ahead of " .. d.base_ref,
        "AhoyDim" },
    })
  end
  if not d.upstream then
    local cmd = "git push -u origin " .. (d.branch or "HEAD")
    b:add({ label("push"), { "not pushed  ", "AhoyWarn" }, { cmd, "AhoyKey" } }, "⏎ copy", copy_row(cmd))
  elseif d.unpushed > 0 then
    b:add({ label("push"), { "↑" .. d.unpushed .. " unpushed  ", "AhoyWarn" }, { "git push", "AhoyKey" } }, "⏎ copy",
      copy_row("git push"))
  else
    b:add({ label("push"), { "✓ up to date with " .. d.upstream, "AhoyOk" } })
  end
  if d.ahead ~= 0 then
    local cmd = "gh pr create --fill --base " .. d.base
    b:add({ label("create"), { cmd, "AhoyKey" } }, "⏎ copy", copy_row(cmd))
  end
  for _, c in ipairs(d.commits) do
    b:add({ { ui.pad("", LW) }, { c.oid .. " ", "AhoyAccent" }, { c.subject } }, util.ago(c.at, d.now))
  end
  return b:result()
end

-- Remote (open PR) -------------------------------------------------------------

local function merge_status(pr)
  local base = pr.base or "base"
  if pr.draft then
    return "draft", "AhoyDim"
  elseif pr.mergeable == "CONFLICTING" or pr.merge_state == "DIRTY" then
    return "✗ conflicts with " .. base, "AhoyError"
  elseif pr.merge_state == "BEHIND" then
    return "↓ behind " .. base, "AhoyWarn"
  elseif pr.merge_state == "BLOCKED" then
    local why = pr.review == "CHANGES_REQUESTED" and "changes requested"
      or gh.ci_failing(pr) and "checks failing"
      or gh.ci_pending(pr) and "checks running"
      or pr.review == "REVIEW_REQUIRED" and "review required"
      or "branch protection"
    return "● blocked: " .. why, "AhoyWarn"
  elseif pr.merge_state == "CLEAN" or pr.merge_state == "HAS_HOOKS" then
    return "✓ ready to merge", "AhoyOk"
  elseif pr.merge_state == "UNSTABLE" then
    return "✓ mergeable (non-required checks failing)", "AhoyWarn"
  end
  return "? mergeability unknown", "AhoyDim"
end

local function checks_segs(ci)
  if not ci or ci.total == 0 then
    return { { "no checks", "AhoyDim" } }
  end
  local parts = {}
  if #ci.failing > 0 then
    parts[#parts + 1] = { "✗ " .. #ci.failing .. " failing", "AhoyError" }
  end
  if ci.pending > 0 then
    parts[#parts + 1] = { "● " .. ci.pending .. " running", "AhoyWarn" }
  end
  parts[#parts + 1] = { ("✓ %d/%d"):format(ci.passed, ci.total), #parts == 0 and "AhoyOk" or "AhoyDim" }
  return ui.summary(parts)
end

local function reviewers_segs(pr, hide_bots)
  local segs = {}
  for _, r in ipairs(pr.reviewers) do
    if not (hide_bots and r.bot) then
      local ic = ui.review_icon[r.state] or { "?", "AhoyDim" }
      if #segs > 0 then
        segs[#segs + 1] = { "  " }
      end
      segs[#segs + 1] = { ic[1] .. " ", ic[2] }
      segs[#segs + 1] = { r.who, r.team and "AhoyDim" or nil }
    end
  end
  if #segs == 0 then
    return { { "no reviewers yet", "AhoyDim" } }
  end
  return segs
end

local function render_pr(d, width)
  local pr = d.pr
  local b = ui.builder(width)
  local open = actions.row(pr.url)

  local right = pr.draft and "draft" or (pr.state or "open"):lower()
  if pr.author and pr.author ~= d.login then
    right = "by " .. pr.author .. " · " .. right
  end
  b:add({ { "#" .. pr.number .. " ", "AhoyAccent" }, { pr.title, "AhoyHeroTitle" } }, right, open)

  local checks_keys = actions.row(pr.url .. "/checks", pr.ci and pr.ci.failing[1] and function()
    actions.log_failed(pr.ci.failing[1], pr.repo)
  end or nil)
  b:add(vim.list_extend({ label("checks") }, checks_segs(pr.ci)), nil, checks_keys)

  b:add(vim.list_extend({ label("reviews") }, reviewers_segs(pr, d.hide_bots)), nil, open)

  local ms, mhl = merge_status(pr)
  b:add({ label("merge"), { ms, mhl } }, nil, open)

  b:add({
    label("diff"),
    { "+" .. pr.additions, "AhoyOk" },
    { " −" .. pr.deletions, "AhoyError" },
    { " · " .. plural(pr.files, "file") .. " · " .. plural(pr.commits, "commit") .. " · ", "AhoyDim" },
    { (pr.base or "?") .. " ← " .. (pr.head or "?"), "AhoyBranch" },
  }, nil, actions.row(pr.url .. "/files"))

  local t = { "opened " .. util.ago(pr.created, d.now) }
  if pr.last_commit then
    t[#t + 1] = "last commit " .. util.ago(pr.last_commit, d.now)
  end
  t[#t + 1] = "updated " .. util.ago(pr.updated, d.now)
  local nthreads = #pr.threads
  if nthreads > 0 then
    t[#t + 1] = plural(nthreads, "open thread")
  end
  b:add({ label("time"), { table.concat(t, " · "), "AhoyDim" } }, nil, open)

  for _, ch in ipairs(pr.ci and pr.ci.failing or {}) do
    local why = ch.conclusion and ch.conclusion ~= "FAILURE" and (" (" .. ch.conclusion:lower() .. ")") or ""
    b:add({ { ui.pad("", LW) }, { "✗ " .. (ch.name or "check") .. why, "AhoyError" } },
      ch.run_id and "⏎ log" or nil,
      actions.row(ch.url, function()
        actions.log_failed(ch, pr.repo)
      end))
  end
  return b:result()
end

return {
  name = "pr",
  title = "Pull request",
  slots = { "hero", "card" },
  wide = true, -- full row when used as a card
  when = function(ctx)
    return ctx.root ~= nil and ctx.branch ~= nil
  end,
  fetch = function(ctx, done)
    if not ctx.pr then
      return fetch_local(ctx, done)
    end
    gh.pr(ctx, function(m, err)
      if err then
        return done(nil, err)
      end
      done({ mode = "pr", pr = m.pr, login = m.login, hide_bots = gh.cfg().hide_bots, now = os.time() })
    end)
  end,
  render = function(d, _, width)
    if d.mode == "local" then
      return render_local(d, width)
    end
    return render_pr(d, width)
  end,
  _parse_shortstat = parse_shortstat,
  _merge_status = merge_status,
}
