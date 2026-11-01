-- Unresolved review threads on this branch's PR. <CR> jumps to file:line, `o` opens the thread.
local gh = require("ahoy.gh")
local ui = require("ahoy.ghui")
local util = require("ahoy.util")
local actions = require("ahoy.actions")

---Last two path components: "lua/ahoy/x.lua" → "ahoy/x.lua".
local function short(path)
  return (path or "?"):match("([^/]+/[^/]+)$") or path or "?"
end

return {
  name = "threads",
  title = "Unresolved threads",
  slots = { "card", "ticker" },
  empty = "no unresolved threads ✓",
  when = function(ctx)
    return ctx.pr ~= nil
  end,
  fetch = function(ctx, done)
    gh.pr(ctx, function(m, err)
      if err then
        return done(nil, err)
      end
      if #m.pr.threads == 0 then
        return done(nil)
      end
      done({ threads = m.pr.threads, now = os.time() })
    end)
  end,
  render = function(d, slot, width)
    if slot == "ticker" then
      local waiting = 0
      for _, t in ipairs(d.threads) do
        waiting = waiting + (t.waiting and 1 or 0)
      end
      return {
        lines = {
          ui.summary({
            { #d.threads .. " unresolved", "AhoyWarn" },
            waiting > 0 and { waiting .. " waiting on you", "AhoyError" } or nil,
          }),
        },
      }
    end
    local b = ui.builder(width)
    for _, t in ipairs(d.threads) do
      local loc = short(t.path) .. (t.line and (":" .. t.line) or "")
      local right = {}
      if t.outdated then
        right[#right + 1] = { "outdated · ", "AhoyDim" }
      end
      if t.count > 1 then
        right[#right + 1] = { t.count .. " comments · ", "AhoyDim" }
      end
      right[#right + 1] = { util.ago(t.at, d.now), "AhoyDim" }
      b:add({
        t.waiting and { "● ", "AhoyWarn" } or { "○ ", "AhoyDim" },
        { loc .. "  ", t.outdated and "AhoyDim" or "AhoyPath" },
        { (t.who or "?") .. ": ", "AhoyAccent" },
        { t.text or "" },
      }, right, actions.row(t.url, function(ctx)
        actions.jump(t.path, t.line, ctx)
      end))
    end
    return b:result()
  end,
}
