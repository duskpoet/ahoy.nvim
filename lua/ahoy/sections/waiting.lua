-- Waiting on me: review requests · unresolved threads on my PRs · my failing CI · ready to merge · @mentions.
local gh = require("ahoy.gh")
local ui = require("ahoy.ghui")
local util = require("ahoy.util")
local actions = require("ahoy.actions")

local LABEL_W = 8

---Build the ordered item list from the main model.
local function items(m, max_reviews)
  local out = {}
  for i, pr in ipairs(m.requested) do
    if max_reviews and i > max_reviews then
      out[#out + 1] = { kind = "older", n = #m.requested - max_reviews }
      break
    end
    out[#out + 1] = { kind = "review", pr = pr }
  end
  for _, pr in ipairs(m.mine) do
    if (pr.waiting_threads or 0) > 0 then
      out[#out + 1] = { kind = "threads", pr = pr, n = pr.waiting_threads }
    end
  end
  for _, pr in ipairs(m.mine) do
    if gh.ci_failing(pr) then
      out[#out + 1] = { kind = "ci", pr = pr, check = pr.ci.failing[1] }
    end
  end
  for _, pr in ipairs(m.mine) do
    if gh.ready_to_merge(pr) then
      out[#out + 1] = { kind = "merge", pr = pr }
    end
  end
  for _, pr in ipairs(m.mentions) do
    out[#out + 1] = { kind = "mention", pr = pr }
  end
  return out
end

local STYLE = {
  review = { "◎", "AhoyInfo", "review" },
  threads = { "✎", "AhoyWarn", "threads" },
  ci = { "✗", "AhoyError", "CI" },
  merge = { "✓", "AhoyOk", "merge" },
  mention = { "@", "AhoyAccent", "mention" },
}

local function row_action(it)
  local pr = it.pr
  if it.kind == "review" then
    return actions.row(pr.url, function(ctx)
      actions.review(pr, ctx)
    end)
  elseif it.kind == "threads" then
    return actions.row(pr.url, function(ctx)
      actions.my_pr(pr, ctx)
    end)
  elseif it.kind == "ci" then
    local check = it.check or {}
    return actions.row(check.url or pr.url, function()
      actions.log_failed(check, pr.repo)
    end)
  end
  return actions.row(pr.url)
end

return {
  name = "waiting",
  title = "Waiting on me",
  slots = { "card", "ticker", "hero" },
  empty = "inbox zero ✓",
  fetch = function(ctx, done)
    gh.main(ctx, function(m, err)
      if err then
        return done(nil, err)
      end
      local list = items(m, gh.cfg().max_reviews)
      if #list == 0 then
        return done(nil)
      end
      done({ items = list, repo = ctx.repo, now = os.time() })
    end)
  end,
  render = function(d, slot, width)
    if slot == "ticker" then
      local count = {}
      for _, it in ipairs(d.items) do
        local k = it.kind == "older" and "review" or it.kind
        count[k] = (count[k] or 0) + (it.kind == "older" and it.n or 1)
      end
      local parts = {}
      for _, k in ipairs({ "review", "threads", "ci", "merge", "mention" }) do
        if count[k] then
          local label = k == "threads" and "thread" or STYLE[k][3]
          if count[k] > 1 and k ~= "ci" then
            label = label .. "s"
          end
          parts[#parts + 1] = { ("%s %d %s"):format(STYLE[k][1], count[k], label), STYLE[k][2] }
        end
      end
      return { lines = { ui.summary(parts) } }
    end

    local b = ui.builder(width)
    for _, it in ipairs(d.items) do
      if it.kind == "older" then
        local url = "https://github.com/pulls?q=" .. vim.uri_encode(gh.REVIEW_SEARCH)
        b:add({
          { "  " .. ui.pad("", LABEL_W) .. " " },
          { ("+%d older review request%s"):format(it.n, it.n == 1 and "" or "s"), "AhoyDim" },
        }, nil, actions.row(url))
        goto continue
      end
      local pr, st = it.pr, STYLE[it.kind]
      local label = st[3]
      if it.kind == "threads" then
        label = it.n .. (it.n == 1 and " thread" or " threads")
      end
      local check = it.kind == "ci" and it.check and it.check.name and { "⟨" .. it.check.name .. "⟩ ", "AhoyError" }
      local right = util.ago(pr.updated, d.now)
      if (it.kind == "review" or it.kind == "mention") and pr.author then
        right = pr.author .. " · " .. right
      end
      local left = {
        { st[1] .. " ", st[2] },
        { ui.pad(label, LABEL_W) .. " ", st[2] },
        { gh.ref(pr, d.repo) .. " ", "AhoyAccent" },
      }
      if check then
        left[#left + 1] = check
      end
      left[#left + 1] = { pr.title, pr.draft and "AhoyDim" or nil }
      b:add(left, right, row_action(it))
      ::continue::
    end
    return b:result()
  end,
  _items = items,
}
