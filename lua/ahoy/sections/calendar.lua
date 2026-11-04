-- Today's calendar. As the hero (the default in every layout): the current/next meeting with a
-- live countdown, the working-day strip, then the day's agenda. As a card: just the agenda.
-- Never empty and never hidden: no ICS file → a setup hint (with the day strip), no events →
-- "no meetings today". Renders against the current time; the 1-minute clock keeps it fresh.
local cal = require("ahoy.calendar")
local tz = require("ahoy.tz")
local ui = require("ahoy.ghui")
local actions = require("ahoy.actions")
local nm = require("ahoy.sections.next_meeting")

-- Past events collapse into one row once the agenda is longer than this (hero only).
local COLLAPSE_AFTER = 6

local function agenda_row(b, e, now)
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

local function agenda(b, d, now, collapse)
  local events = d.events
  local skip = 0
  if collapse and #events > COLLAPSE_AFTER then
    for _, e in ipairs(events) do
      if not e.allday and e.stop <= now then
        skip = skip + 1
      end
    end
    skip = skip > 1 and skip or 0
  end
  if skip > 0 then
    b:add({ { "  ✓ " .. skip .. " earlier today", "AhoyDim" } })
  end
  for _, e in ipairs(events) do
    if skip == 0 or e.allday or e.stop > now then
      agenda_row(b, e, now)
    end
  end
end

local function warnings(b, d)
  for _, w in ipairs(d.warnings or {}) do
    b:add({ { "⚠ " .. w, "AhoyWarn" } })
  end
end

local function render_unconfigured(d, width)
  local b = ui.builder(width)
  local path = vim.fn.fnamemodify(cal.url_file(), ":~")
  b:add({ { "◌ ", "AhoyDim" }, { "Calendar not connected", "AhoyHeroTitle" } })
  b:add({ { "  Put your Google Calendar secret iCal address in ", "AhoyDim" }, { path, "AhoyPath" },
    { " and chmod 600 it", "AhoyDim" } })
  local bar = nm._day_bar(d, os.time(), width)
  if bar then
    b:add(bar)
  end
  return b:result()
end

local function render_hero(d, width)
  local now = os.time()
  local b = ui.builder(width)
  nm._headline(b, d, now)
  local bar = nm._day_bar(d, now, width)
  if bar then
    b:add(bar)
  end
  if #d.events > 0 then
    b:add({})
    agenda(b, d, now, true)
  end
  warnings(b, d)
  return b:result()
end

local function render_card(d, width)
  local now = os.time()
  local b = ui.builder(width)
  if #d.events == 0 then
    b:add({ { "no events today", "AhoyDim" } })
  end
  agenda(b, d, now, false)
  local foot = { { "fetched " .. cal.fmt(d.fetched), "AhoyDim" } }
  for _, w in ipairs(d.warnings or {}) do
    foot[#foot + 1] = { "  ⚠ " .. w, "AhoyWarn" }
  end
  b:add(foot)
  return b:result()
end

return {
  name = "calendar",
  title = function(d)
    local s = tz.strftime("%a %d %b", (d and d.fetched) or os.time(), cal.zone())
    return "Today · " .. s:gsub(" 0(%d)", " %1")
  end,
  slots = { "hero", "card" },
  fetch = function(ctx, done)
    if not cal.configured() then
      local ws, we = tz.day_bounds(cal.zone(), os.time())
      return done({ unconfigured = true, events = {}, day_start = ws, day_end = we })
    end
    cal.today(ctx, done)
  end,
  render = function(d, slot, width)
    if d.unconfigured then
      return render_unconfigured(d, width)
    end
    if slot == "hero" then
      return render_hero(d, width)
    end
    return render_card(d, width)
  end,
}
