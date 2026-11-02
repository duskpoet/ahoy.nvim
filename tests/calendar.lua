-- Headless test for the calendar: tz, ICS parsing/recurrence, sections, and the secret-URL handling.
--   nvim --headless -u NONE -i NONE -c 'luafile tests/calendar.lua'
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.cmd("runtime plugin/ahoy.lua")

local failures = 0
local function check(name, cond)
  print((cond and "ok   " or "FAIL ") .. name)
  if not cond then
    failures = failures + 1
  end
end

local main = function()
  local util = require("ahoy.util")
  local tz = require("ahoy.tz")
  local ics = require("ahoy.ics")

  -- parsing primitives ---------------------------------------------------------
  local n, p, v = ics.parse_line('ATTENDEE;CN="Doe, J: Jr";PARTSTAT=DECLINED:mailto:j@x.com')
  check("parse_line quoted param", n == "ATTENDEE" and p.CN == "Doe, J: Jr" and p.PARTSTAT == "DECLINED"
    and v == "mailto:j@x.com")
  check("unescape", ics.unescape("a\\, b\\; c\\nd\\\\") == "a, b; c\nd\\")
  check("unfold CRLF", ics.unfold("A:12\r\n 34\r\nB:x\r\n") == "A:1234\nB:x\n")
  check("duration", ics.parse_duration("PT1H30M") == 5400 and ics.parse_duration("P1D") == 86400
    and ics.parse_duration("-PT15M") == -900 and ics.parse_duration("P1W") == 604800)
  local r = ics.parse_rrule("FREQ=MONTHLY;BYDAY=-1FR,2TU;INTERVAL=2;BYSETPOS=1")
  check("rrule parse", r.freq == "MONTHLY" and r.interval == 2 and r.byday[1].ord == -1 and r.byday[1].wd == 5
    and r.byday[2].ord == 2 and r.unsupported[1] == "BYSETPOS")

  -- expansion on Tue 2026-11-10, displayed in Europe/Berlin ----------------------
  local f = assert(io.open("tests/fixtures/calendar.ics"))
  local text = f:read("*a"):gsub("\n", "\r\n") -- real feeds are CRLF
  f:close()
  local cal = ics.parse(text)
  check("parsed events (VALARM ignored)", #cal.events == 17 and cal.name == "me@example.com")
  local zone = "Europe/Berlin"
  local noon = tz.to_utc(zone, util.days_from_civil(2026, 11, 10) * 86400 + 12 * 3600)
  local ws, we = tz.day_bounds(zone, noon)
  check("day bounds", we - ws == 86400 and tz.strftime("%H:%M", ws, zone) == "00:00")
  local occ = ics.expand(cal, ws, we, { zone = zone })
  local by = {}
  for _, o in ipairs(occ) do
    by[o.title] = o
  end
  local function at(o)
    return o and tz.strftime("%H:%M", o.start, zone)
  end
  check("weekly BYDAY across DST (09:30 CET)", at(by.Standup) == "09:30" and by.Standup.stop - by.Standup.start == 900)
  check("X-GOOGLE-CONFERENCE link", by.Standup.link == "https://meet.google.com/aaa-bbbb-ccc")
  local sam = by["1:1 with Sam, weekly-ish"]
  check("biweekly in LA → 17:00 Berlin", at(sam) == "17:00")
  check("link from folded description", sam and sam.link == "https://meet.google.com/abc-defg-hij")
  check("override moved", at(by["Planning (moved)"]) == "15:00" and by.Planning == nil)
  check("cancelled instance dropped", by.Retro == nil or by.Retro.cancelled)
  check("monthly 2nd Tuesday", at(by["Town hall"]) == "18:00")
  check("monthly last Friday absent", by["Last-Friday demo"] == nil)
  check("COUNT exhausted", by["Short daily"] == nil)
  check("COUNT not yet exhausted", at(by["Long daily"]) == "08:15")
  check("UNTIL passed", by["Ended series"] == nil)
  check("unsupported BYSETPOS warns", by["Setpos thing"] and by["Setpos thing"].warn:find("BYSETPOS") ~= nil)
  check("all-day", by["Release day"] and by["Release day"].allday and by["Release day"].free)
  check("yearly all-day", by.Birthday and by.Birthday.allday)
  check("declined (case-insensitive email)", by["Optional sync"] and by["Optional sync"].declined)
  check("unknown TZID → floating + warn", at(by["Outlook invite"]) == "18:30" and by["Outlook invite"].warn ~= nil)
  check("other day absent", by["Yesterday only"] == nil)
  check("all-day first", occ[1].allday and occ[2].allday and not occ[3].allday)

  -- EXDATE on the 11th
  local ws2, we2 = tz.day_bounds(zone, noon + 86400)
  local has_standup = false
  for _, o in ipairs(ics.expand(cal, ws2, we2, { zone = zone })) do
    has_standup = has_standup or o.title == "Standup"
  end
  check("EXDATE removes instance", not has_standup)
  -- Saturday: weekday-only standup absent
  local ws3, we3 = tz.day_bounds(zone, noon + 4 * 86400)
  local sat = false
  for _, o in ipairs(ics.expand(cal, ws3, we3, { zone = zone })) do
    sat = sat or o.title == "Standup"
  end
  check("BYDAY excludes weekend", not sat)
  -- same feed, displayed in LA: standup on Tue 10th is 00:30 local
  local la = "America/Los_Angeles"
  local lws, lwe = tz.day_bounds(la, tz.to_utc(la, util.days_from_civil(2026, 11, 10) * 86400 + 12 * 3600))
  local s_la
  for _, o in ipairs(ics.expand(cal, lws, lwe, { zone = la })) do
    if o.title == "Standup" then
      s_la = tz.strftime("%H:%M", o.start, la)
    end
  end
  check("display zone shifts times", s_la == "00:30")

  -- secret URL handling ---------------------------------------------------------
  local cal_mod = require("ahoy.calendar")
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local urlf = dir .. "/ics_url"
  vim.fn.writefile({ "  https://calendar.google.com/calendar/ical/secret%40x/private-abc/basic.ics  " }, urlf)
  vim.uv.fs_chmod(urlf, tonumber("644", 8))
  local url, warn = cal_mod.read_url(urlf)
  check("read_url trims", url == "https://calendar.google.com/calendar/ical/secret%40x/private-abc/basic.ics")
  check("perm warning on 644", warn and warn:find("chmod 600") ~= nil)
  vim.uv.fs_chmod(urlf, tonumber("600", 8))
  local _, warn2 = cal_mod.read_url(urlf)
  check("no warning on 600", warn2 == nil)
  vim.fn.writefile({ "webcal://example.com/x.ics" }, urlf)
  check("webcal → https", cal_mod.read_url(urlf) == "https://example.com/x.ics")
  vim.fn.writefile({ "not a url" }, urlf)
  local u3, _, e3 = cal_mod.read_url(urlf)
  check("bad file content", u3 == nil and e3:find("doesn't contain") ~= nil)

  -- curl gets the URL on stdin, never in argv; errors don't echo it
  vim.fn.writefile({ "https://example.com/private-SECRET/basic.ics" }, urlf)
  local seen
  local orig_run = util.run
  util.run = function(cmd, opts, cb)
    seen = { cmd = cmd, stdin = opts.stdin }
    vim.schedule(function()
      cb({ code = 22, stdout = "", stderr = "curl: (22) The requested URL returned error: 404 https://example.com/private-SECRET/basic.ics" })
    end)
  end

  -- dashboard ---------------------------------------------------------------------
  -- Pick a fixed-offset zone where it's currently ~12:00, so ±3h events stay "today".
  local utc_h = tonumber(os.date("!%H"))
  local h = (12 - utc_h) % 24
  if h > 12 then
    h = h - 24
  end
  local zname = ("<X>%d"):format(-h)
  require("ahoy").setup({
    show_on_startup = false,
    browser = "open",
    timezone = zname,
    calendar = { url_file = urlf, day_start = 8, day_end = 18 },
    layouts = { main = { header = "status", hero = { "next_meeting" }, cards = { "calendar" }, tickers = { "next_meeting" } } },
  })
  -- not a git repo → global; force main layout by faking context
  require("ahoy.context").detect = function(cb)
    vim.schedule(function()
      cb({ cwd = dir, time = os.time(), kind = "main" })
    end)
  end
  local ahoy = require("ahoy")
  vim.o.columns = 170
  ahoy.open()
  local function text_()
    return table.concat(vim.api.nvim_buf_get_lines(ahoy._state.buf, 0, -1, false), "\n")
  end
  local function settled()
    local s = ahoy._state
    if not s.ctx then
      return false
    end
    for _, st in pairs(s.states) do
      if st.status == "loading" then
        return false
      end
    end
    return true
  end
  vim.wait(3000, settled, 20)
  local t = text_()
  check("curl: URL not in argv", seen and not table.concat(seen.cmd, " "):find("SECRET"))
  check("curl: URL on stdin", seen and seen.stdin:find("private%-SECRET") ~= nil and vim.tbl_contains(seen.cmd, "-K"))
  check("curl error shown without URL", t:find("404") ~= nil and t:find("SECRET") == nil)

  -- now serve a live feed relative to "now"
  local now = os.time()
  local function z(sec)
    return os.date("!%Y%m%dT%H%M%SZ", sec)
  end
  local live = table.concat({
    "BEGIN:VCALENDAR", "X-WR-CALNAME:me@example.com",
    "BEGIN:VEVENT", "UID:a", "SUMMARY:Current sync", "DTSTART:" .. z(now - 600), "DTEND:" .. z(now + 1200), "END:VEVENT",
    "BEGIN:VEVENT", "UID:b", "SUMMARY:Design review", "DTSTART:" .. z(now + 2400), "DTEND:" .. z(now + 4200),
    "X-GOOGLE-CONFERENCE:https://meet.google.com/xyz-abcd-efg", "END:VEVENT",
    "BEGIN:VEVENT", "UID:c", "SUMMARY:Later chat", "DTSTART:" .. z(now + 7200), "DTEND:" .. z(now + 9000), "END:VEVENT",
    "BEGIN:VEVENT", "UID:d", "SUMMARY:Morning thing", "DTSTART:" .. z(now - 10800), "DTEND:" .. z(now - 9000), "END:VEVENT",
    "BEGIN:VEVENT", "UID:e", "SUMMARY:Skipped", "DTSTART:" .. z(now + 3000), "DTEND:" .. z(now + 3600),
    "ATTENDEE;PARTSTAT=DECLINED:mailto:me@example.com", "END:VEVENT",
    "END:VCALENDAR", "",
  }, "\r\n")
  util.run = function(cmd, opts, cb)
    vim.schedule(function()
      cb({ code = 0, stdout = live, stderr = "" })
    end)
  end
  ahoy.refresh()
  vim.wait(3000, settled, 20)
  t = text_()
  if os.getenv("AHOY_DUMP") then
    print(t)
  end
  util.run = orig_run
  check("hero: current meeting", t:find("● now  Current sync") ~= nil and t:find("20m left") ~= nil)
  check("hero: next with countdown", t:find("next  %d%d:%d%d Design review") ~= nil and t:find("in 40m") ~= nil)
  check("hero: day bar", t:find("━") ~= nil and t:find("●") ~= nil and t:find("▆") ~= nil)
  check("hero: fetched at", t:find("fetched %d%d:%d%d") ~= nil)
  check("ticker", t:find("Next meeting  now Current sync") ~= nil)
  check("card: all events", t:find("Morning thing") and t:find("Later chat") and t:find("Skipped"))
  check("card: declined label", t:find("declined") ~= nil)
  check("card: Meet label", t:find("Meet · in 40m") ~= nil)
  check("clock in configured zone", t:find(tz.strftime("%H:%M", os.time(), zname), 1, true) ~= nil)
  check("declined not next", not t:find("next  %d%d:%d%d Skipped"))

  local opened
  vim.ui.open = function(u)
    opened = u
  end
  for i, l in ipairs(vim.api.nvim_buf_get_lines(ahoy._state.buf, 0, -1, false)) do
    local col = l:find("Design review  ", 1, true) or (l:find("Design review", 1, true) and l:find("Meet", 1, true) and l:find("Design review", 1, true))
    if col then
      vim.api.nvim_win_set_cursor(0, { i, col - 1 })
      vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
      break
    end
  end
  check("<CR> opens Meet link", opened == "https://meet.google.com/xyz-abcd-efg")

  -- no remaining meetings → next_meeting empty (hero falls through)
  local nm = require("ahoy.sections.next_meeting")
  local model = cal_mod.build(table.concat({ "BEGIN:VCALENDAR", "BEGIN:VEVENT", "UID:x", "SUMMARY:Done",
    "DTSTART:" .. z(now - 7200), "DTEND:" .. z(now - 3600), "END:VEVENT", "END:VCALENDAR" }, "\r\n"), now)
  local got = "unset"
  util.shared({}, "calendar", function(fin) fin(model) end, function() end)
  local ctx = {}
  util.shared(ctx, "calendar", function(fin) fin(model) end, function() end)
  nm.fetch(ctx, function(d, e)
    got = d == nil and e == nil and "empty" or "data"
  end)
  vim.wait(500, function() return got ~= "unset" end, 10)
  check("no upcoming → empty", got == "empty")

  vim.fn.delete(dir, "rf")
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
  print("ERROR " .. tostring(err))
  failures = failures + 1
end
print(failures == 0 and "ALL PASSED" or (failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)
