-- Next (or current) meeting with a live countdown and a day-progress strip. Hero or ticker.
-- Renders against the current time, so the 1-minute clock keeps it fresh without refetching.
local cal = require("ahoy.calendar")
local tz = require("ahoy.tz")
local ui = require("ahoy.ghui")
local actions = require("ahoy.actions")

local LW = 6

local function label(s)
  return { ui.pad(s, LW), "AhoyDim" }
end

local function range(e)
  return cal.fmt(e.start) .. "–" .. cal.fmt(e.stop)
end

local function keys(e)
  return e.link and actions.row(e.link) or nil
end

local function urgency(secs)
  if secs <= 300 then
    return "AhoyError"
  elseif secs <= 900 then
    return "AhoyWarn"
  end
  return "AhoyAccent"
end

---Working-day strip: elapsed ━, remaining ─, meetings ▆, now ●.
local function day_bar(d, now, width)
  local c = cal.cfg()
  local zone = cal.zone()
  local day0 = tz.day(zone, now) * 86400
  local s = tz.to_utc(zone, day0 + (c.day_start or 9) * 3600)
  local e = tz.to_utc(zone, day0 + (c.day_end or 18) * 3600)
  local meets = cal.meetings(d)
  for _, m in ipairs(meets) do
    s = math.min(s, math.max(m.start, d.day_start))
    e = math.max(e, math.min(m.stop, d.day_end))
  end
  local left, right = cal.fmt(s) .. " ", " " .. cal.fmt(e)
  local n = width - #left - #right
  if n < 10 or e <= s then
    return nil
  end
  local segs = { { left, "AhoyDim" } }
  local function put(ch, hl)
    local last = segs[#segs]
    if last[2] == hl and #segs > 1 then
      last[1] = last[1] .. ch
    else
      segs[#segs + 1] = { ch, hl }
    end
  end
  for i = 0, n - 1 do
    local a = s + (e - s) * i / n
    local b = s + (e - s) * (i + 1) / n
    local busy = false
    for _, m in ipairs(meets) do
      if m.start < b and m.stop > a then
        busy = true
        break
      end
    end
    if a <= now and now < b then
      put("●", "AhoyWarn")
    elseif b <= now then
      put(busy and "▆" or "━", busy and "AhoyDim" or "AhoyAccent")
    else
      put(busy and "▆" or "─", busy and "AhoyInfo" or "AhoyBorder")
    end
  end
  segs[#segs + 1] = { right, "AhoyDim" }
  return segs
end

local function detail(e)
  local segs = { label(""), { range(e), "AhoyDim" } }
  local l = cal.link_label(e.link)
  if l then
    segs[#segs + 1] = { "  ⏎ " .. l, "AhoyKey" }
  elseif e.location and e.location ~= "" then
    segs[#segs + 1] = { "  " .. e.location:gsub("\n", " "), "AhoyDim" }
  end
  return segs
end

local function render_hero(d, width)
  local now = os.time()
  local cur, nxt = cal.split(d, now)
  local b = ui.builder(width)
  if cur[1] then
    local e = cur[1]
    b:add({ { "● now  ", "AhoyOk" }, { e.title, "AhoyHeroTitle" } }, { { cal.countdown(e.stop - now) .. " left", "AhoyOk" } },
      keys(e))
    b:add(detail(e), "fetched " .. cal.fmt(d.fetched), keys(e))
    if #cur > 1 then
      b:add({ label("also"), { cur[2].title .. (#cur > 2 and (" (+" .. (#cur - 2) .. ")") or ""), "AhoyDim" } }, nil,
        keys(cur[2]))
    end
    if nxt[1] then
      local secs = nxt[1].start - now
      b:add({ label("next"), { cal.fmt(nxt[1].start) .. " ", "AhoyAccent" }, { nxt[1].title } },
        { { "in " .. cal.countdown(secs), urgency(secs) } }, keys(nxt[1]))
    end
  elseif nxt[1] then
    local e = nxt[1]
    local secs = e.start - now
    b:add({ { "▶ ", urgency(secs) }, { e.title, "AhoyHeroTitle" } }, { { "in " .. cal.countdown(secs), urgency(secs) } },
      keys(e))
    b:add(detail(e), "fetched " .. cal.fmt(d.fetched), keys(e))
    if nxt[2] then
      local more = #nxt - 2
      b:add({
        label("then"),
        { cal.fmt(nxt[2].start) .. " ", "AhoyAccent" },
        { nxt[2].title },
        more > 0 and { ("  +%d more today"):format(more), "AhoyDim" } or nil,
      }, nil, keys(nxt[2]))
    end
  else
    b:add({ { "✓ ", "AhoyOk" }, { "No more meetings today", "AhoyHeroTitle" } }, "fetched " .. cal.fmt(d.fetched))
  end
  local bar = day_bar(d, now, width)
  if bar then
    b:add(bar)
  end
  for _, w in ipairs(d.warnings or {}) do
    b:add({ { "⚠ " .. w, "AhoyWarn" } })
  end
  return b:result()
end

local function render_ticker(d, width)
  local now = os.time()
  local cur, nxt = cal.split(d, now)
  local b = ui.builder(width)
  if cur[1] then
    local e = cur[1]
    local segs = { { "now ", "AhoyOk" }, { e.title }, { " · " .. cal.countdown(e.stop - now) .. " left", "AhoyDim" } }
    if nxt[1] then
      segs[#segs + 1] = { "  then " .. cal.fmt(nxt[1].start) .. " " .. nxt[1].title, "AhoyDim" }
    end
    b:add(segs, nil, keys(e))
  elseif nxt[1] then
    local e = nxt[1]
    local secs = e.start - now
    b:add({ { e.title }, { " in " .. cal.countdown(secs), urgency(secs) }, { " · " .. range(e), "AhoyDim" } }, nil, keys(e))
  else
    b:add({ { "no more meetings today", "AhoyDim" } })
  end
  return b:result()
end

return {
  name = "next_meeting",
  title = "Next meeting",
  slots = { "hero", "ticker", "card" },
  empty = "no more meetings today",
  when = function()
    return cal.configured()
  end,
  fetch = function(ctx, done)
    cal.today(ctx, function(m, err)
      if err then
        return done(nil, err)
      end
      local cur, nxt = cal.split(m, os.time())
      if #cur == 0 and #nxt == 0 then
        return done(nil) -- let the hero fall through (e.g. to idle)
      end
      done(m)
    end)
  end,
  render = function(d, slot, width)
    if slot == "ticker" then
      return render_ticker(d, width)
    end
    return render_hero(d, width)
  end,
  _day_bar = day_bar,
}
