-- Today's events from the ICS feed. Past events dim, the current one marked; <CR> opens the call link.
local cal = require("ahoy.calendar")
local ui = require("ahoy.ghui")
local actions = require("ahoy.actions")

return {
  name = "calendar",
  title = "Today",
  slots = { "card" },
  empty = "no events today",
  when = function()
    return cal.configured()
  end,
  fetch = function(ctx, done)
    cal.today(ctx, function(m, err)
      if err then
        return done(nil, err)
      end
      if #m.events == 0 then
        return done(nil)
      end
      done(m)
    end)
  end,
  render = function(d, _, width)
    local now = os.time()
    local b = ui.builder(width)
    for _, e in ipairs(d.events) do
      local current = not e.allday and e.start <= now and now < e.stop
      local past = not e.allday and e.stop <= now
      local dim = past or e.declined
      local time = e.allday and ui.pad("all day", 11) or (cal.fmt(e.start) .. "–" .. cal.fmt(e.stop))
      local left = {
        current and { "▶ ", "AhoyOk" } or { "  " },
        { time .. "  ", dim and "AhoyDim" or "AhoyAccent" },
      }
      if e.warn then
        left[#left + 1] = { "⚠ ", "AhoyWarn" }
      end
      left[#left + 1] = { e.title, dim and "AhoyDim" or (current and "AhoyOk" or nil) }

      local right = {}
      local l = cal.link_label(e.link)
      if e.declined then
        right[#right + 1] = { "declined", "AhoyDim" }
      elseif current then
        right[#right + 1] = { cal.countdown(e.stop - now) .. " left", "AhoyOk" }
      elseif not past and not e.allday then
        right[#right + 1] = { "in " .. cal.countdown(e.start - now), "AhoyDim" }
      end
      if l and not past and not e.declined then
        table.insert(right, 1, { l .. (#right > 0 and " · " or ""), "AhoyKey" })
      end
      b:add(left, #right > 0 and right or nil, e.link and actions.row(e.link) or nil)
    end
    local foot = { { "fetched " .. cal.fmt(d.fetched), "AhoyDim" } }
    for _, w in ipairs(d.warnings or {}) do
      foot[#foot + 1] = { "  ⚠ " .. w, "AhoyWarn" }
    end
    b:add(foot)
    return b:result()
  end,
}
