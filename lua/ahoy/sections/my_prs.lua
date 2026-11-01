-- My open PRs: CI, review decision, mergeability, age. <CR> checks out and reopens in the PR layout.
local gh = require("ahoy.gh")
local ui = require("ahoy.ghui")
local util = require("ahoy.util")
local actions = require("ahoy.actions")

local REVIEW = {
  APPROVED = { "approved", "AhoyOk" },
  CHANGES_REQUESTED = { "changes", "AhoyError" },
  REVIEW_REQUIRED = { "review", "AhoyDim" },
}

local function tag(pr)
  if pr.draft then
    return { "draft", "AhoyDim" }
  elseif pr.mergeable == "CONFLICTING" then
    return { "conflict", "AhoyError" }
  end
  return REVIEW[pr.review] or { "", nil }
end

return {
  name = "my_prs",
  title = "My PRs",
  slots = { "card", "ticker" },
  empty = "no open PRs",
  fetch = function(ctx, done)
    gh.main(ctx, function(m, err)
      if err then
        return done(nil, err)
      end
      if #m.mine == 0 then
        return done(nil)
      end
      done({ prs = m.mine, repo = ctx.repo, now = os.time() })
    end)
  end,
  render = function(d, slot, width)
    if slot == "ticker" then
      local failing, approved = 0, 0
      for _, pr in ipairs(d.prs) do
        failing = failing + (gh.ci_failing(pr) and 1 or 0)
        approved = approved + (pr.review == "APPROVED" and 1 or 0)
      end
      return {
        lines = {
          ui.summary({
            { #d.prs .. " open", "AhoyAccent" },
            failing > 0 and { "✗ " .. failing .. " failing", "AhoyError" } or nil,
            approved > 0 and { "✓ " .. approved .. " approved", "AhoyOk" } or nil,
          }),
        },
      }
    end

    local b = ui.builder(width)
    for _, pr in ipairs(d.prs) do
      local icon, ihl = ui.ci_icon(pr)
      local t = tag(pr)
      local left = {
        { icon .. " ", ihl },
        { gh.ref(pr, d.repo) .. " ", "AhoyAccent" },
        { pr.title, pr.draft and "AhoyDim" or nil },
      }
      if pr.ci and pr.ci.total > 0 then
        table.insert(left, 3, { ("%d/%d "):format(pr.ci.passed, pr.ci.total), ihl })
      end
      local right = { { util.ago(pr.updated, d.now), "AhoyDim" } }
      if t[1] ~= "" then
        table.insert(right, 1, { t[1], t[2] })
        table.insert(right, 2, { " · ", "AhoyDim" })
      end
      b:add(left, right, actions.row(pr.url, function(ctx)
        actions.my_pr(pr, ctx)
      end))
    end
    return b:result()
  end,
}
