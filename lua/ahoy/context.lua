local util = require("ahoy.util")

local M = {}

local function parse_status(out)
  local g = { dirty = 0, ahead = 0, behind = 0 }
  for line in out:gmatch("[^\n]+") do
    local head = line:match("^# branch%.head (.+)$")
    if head then
      g.detached = head == "(detached)"
      g.branch = not g.detached and head or nil
    end
    g.upstream = line:match("^# branch%.upstream (.+)$") or g.upstream
    local a, b = line:match("^# branch%.ab %+(%d+) %-(%d+)$")
    if a then
      g.ahead, g.behind = tonumber(a), tonumber(b)
    end
    if line:sub(1, 1) ~= "#" then
      g.dirty = g.dirty + 1
    end
  end
  return g
end

local function finish(ctx, cb)
  local branch = ctx.branch
  if not branch or branch == ctx.default_branch then
    ctx.kind = "main"
    return cb(ctx)
  end
  -- Any feature branch uses the `pr` layout; ctx.pr is nil when there is no open PR yet.
  ctx.kind = "pr"
  if not util.has("gh") then
    return cb(ctx)
  end
  util.run(
    { "gh", "pr", "view", "--json", "number,state,url,title,baseRefName" },
    { cwd = ctx.root, env = { GH_PROMPT_DISABLED = "1" } },
    function(r)
      if r.code == 0 then
        local ok, pr = pcall(vim.json.decode, r.stdout)
        if ok and type(pr) == "table" and pr.state == "OPEN" then
          ctx.pr = pr
        end
      end
      cb(ctx)
    end
  )
end

---Gather context once per open. `cb(ctx)` with
---ctx = { cwd, time, kind = "pr"|"main"|"global", root?, branch?, default_branch?, git?, pr? }
function M.detect(cb)
  local ctx = { cwd = vim.fn.getcwd(), time = os.time(), kind = "global" }
  util.run({ "git", "rev-parse", "--show-toplevel" }, { cwd = ctx.cwd }, function(r)
    if r.code ~= 0 then
      return cb(ctx)
    end
    ctx.root = vim.trim(r.stdout)
    local local_branches = {}
    local pending = 3
    local function step()
      pending = pending - 1
      if pending > 0 then
        return
      end
      if not ctx.default_branch then
        ctx.default_branch = local_branches.main and "main" or local_branches.master and "master" or nil
      end
      finish(ctx, cb)
    end

    util.run({ "git", "status", "--porcelain=v2", "--branch" }, { cwd = ctx.root }, function(s)
      ctx.git = s.code == 0 and parse_status(s.stdout) or { dirty = 0, ahead = 0, behind = 0 }
      ctx.branch = ctx.git.branch
      step()
    end)
    util.run({ "git", "symbolic-ref", "--short", "refs/remotes/origin/HEAD" }, { cwd = ctx.root }, function(d)
      if d.code == 0 then
        ctx.default_branch = (vim.trim(d.stdout):gsub("^[^/]+/", ""))
      end
      step()
    end)
    util.run(
      { "git", "branch", "--list", "main", "master", "--format=%(refname:short)" },
      { cwd = ctx.root },
      function(b)
        for name in (b.stdout or ""):gmatch("%S+") do
          local_branches[name] = true
        end
        step()
      end
    )
  end)
end

M._parse_status = parse_status

return M
