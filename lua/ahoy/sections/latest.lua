-- Latest activity by others on my open PRs: comments, reviews, pushes, review-thread replies.
local gh = require("ahoy.gh")
local ui = require("ahoy.ghui")
local util = require("ahoy.util")
local actions = require("ahoy.actions")

---Drop empty COMMENTED reviews (they're just containers for thread comments, shown separately).
local function useful(ev)
  return not (ev.kind == "review" and ev.state == "COMMENTED" and (ev.text or "") == "")
end

return {
  name = "latest",
  title = "Latest",
  slots = { "card", "ticker" },
  empty = "no recent activity on your PRs",
  _useful = useful,
  fetch = function(ctx, done)
    gh.main(ctx, function(m, err)
      if err then
        return done(nil, err)
      end
      local c = gh.cfg()
      local evs = {}
      for _, ev in ipairs(m.events) do
        if useful(ev) and not (c.hide_bots and ev.bot) and #evs < (c.latest or 12) then
          evs[#evs + 1] = ev
        end
      end
      if #evs == 0 then
        return done(nil)
      end
      done({ events = evs, repo = ctx.repo, now = os.time() })
    end)
  end,
  render = function(d, slot, width)
    local b = ui.builder(width)
    for i, ev in ipairs(d.events) do
      if slot == "ticker" and i > 1 then
        break
      end
      local v = ui.verb(ev)
      local left = {
        { (ev.who or "someone") .. " ", "AhoyAccent" },
        { v[1] .. " ", v[2] },
        { gh.ref(ev.pr, d.repo), "AhoyAccent" },
      }
      if ev.kind == "thread" and ev.path then
        left[#left + 1] = { "  " .. vim.fn.fnamemodify(ev.path, ":t") .. (ev.line and (":" .. ev.line) or ""), "AhoyPath" }
      end
      if ev.text and ev.text ~= "" then
        left[#left + 1] = { "  " .. ev.text, "AhoyDim" }
      end
      b:add(left, util.ago(ev.at, d.now), actions.row(ev.url or ev.pr.url))
    end
    return b:result()
  end,
}
