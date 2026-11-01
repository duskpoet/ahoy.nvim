-- Activity on this branch's PR: comments, reviews, pushes, review requests, CI results.
local gh = require("ahoy.gh")
local ui = require("ahoy.ghui")
local util = require("ahoy.util")
local actions = require("ahoy.actions")

local useful = require("ahoy.sections.latest")._useful

return {
  name = "activity",
  title = "Activity",
  slots = { "card", "ticker" },
  empty = "no activity yet",
  when = function(ctx)
    return ctx.pr ~= nil
  end,
  fetch = function(ctx, done)
    gh.pr(ctx, function(m, err)
      if err then
        return done(nil, err)
      end
      local hide = gh.cfg().hide_bots
      local evs = {}
      for _, ev in ipairs(m.pr.events) do
        if useful(ev) and not (hide and ev.bot) then
          evs[#evs + 1] = ev
        end
      end
      if #evs == 0 then
        return done(nil)
      end
      done({ events = evs, repo = m.pr.repo, now = os.time() })
    end)
  end,
  render = function(d, slot, width)
    local b = ui.builder(width)
    for i, ev in ipairs(d.events) do
      if slot == "ticker" and i > 1 then
        break
      end
      local v = ui.verb(ev)
      local left, keys
      if ev.kind == "ci_fail" or ev.kind == "ci_ok" then
        left = { { "CI ", "AhoyAccent" }, { v[1] .. " ", v[2] }, { ev.text or "", v[2] } }
        if ev.check then
          keys = actions.row(ev.url, function()
            actions.log_failed(ev.check, d.repo)
          end)
        end
      else
        left = { { (ev.me and "you" or ev.who or "someone") .. " ", "AhoyAccent" }, { v[1], v[2] } }
        if ev.oid then
          left[#left + 1] = { " " .. ev.oid, "AhoyAccent" }
        end
        if ev.text and ev.text ~= "" then
          local rr = ev.kind == "review_requested"
          left[#left + 1] = { (rr and " " or "  ") .. ev.text, not rr and "AhoyDim" or nil }
        end
      end
      b:add(left, util.ago(ev.at, d.now), keys or actions.row(ev.url))
    end
    return b:result()
  end,
}
