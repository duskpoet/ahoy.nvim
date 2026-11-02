-- iCalendar (RFC 5545) subset: unfolding, VEVENT parsing, and expansion of a time window.
-- Recurrence: FREQ=DAILY/WEEKLY/MONTHLY/YEARLY, INTERVAL, BYDAY (incl. ordinals), BYMONTHDAY,
-- BYMONTH, WKST, UNTIL, COUNT, EXDATE, RDATE, RECURRENCE-ID overrides, TZID.
-- Anything else in an RRULE marks its occurrences with `warn`.
local util = require("ahoy.util")
local tz = require("ahoy.tz")

local M = {}

local WD = { SU = 0, MO = 1, TU = 2, WE = 3, TH = 4, FR = 5, SA = 6 }
local FREQS = { DAILY = true, WEEKLY = true, MONTHLY = true, YEARLY = true }
local MULTI = { EXDATE = true, RDATE = true, ATTENDEE = true }

-- Parsing ---------------------------------------------------------------------------

function M.unfold(text)
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  return (text:gsub("\n[ \t]", ""))
end

function M.unescape(v)
  return (v:gsub("\\(.)", function(c)
    if c == "n" or c == "N" then
      return "\n"
    end
    return c
  end))
end

---"NAME;A=1;B=\"x:y\":value" → name, params, value
function M.parse_line(line)
  local pos, inq, colon = 1, false, nil
  while true do
    local j = line:find('[:"]', pos)
    if not j then
      return nil
    end
    if line:sub(j, j) == '"' then
      inq = not inq
    elseif not inq then
      colon = j
      break
    end
    pos = j + 1
  end
  local head, value = line:sub(1, colon - 1), line:sub(colon + 1)
  local name, rest = head:match("^([^;]+)(.*)$")
  if not name then
    return nil
  end
  local params, p = {}, 1
  while p <= #rest do
    local k, e = rest:match("^;([^=;]+)=()", p)
    if not k then
      break
    end
    local v
    if rest:sub(e, e) == '"' then
      local q = rest:find('"', e + 1, true) or (#rest + 1)
      v, p = rest:sub(e + 1, q - 1), q + 1
    else
      local q = rest:find(";", e, true) or (#rest + 1)
      v, p = rest:sub(e, q - 1), q
    end
    params[k:upper()] = v
  end
  return name:upper(), params, value
end

---"20261102T100000Z" / "20261102T100000" (+TZID) / "20261102" → dt
---dt = { y, m, d, h, mi, s, utc?, tzid?, date? }
function M.parse_dt(value, params)
  local y, m, d, rest = (value or ""):match("^(%d%d%d%d)(%d%d)(%d%d)(.*)$")
  if not y then
    return nil
  end
  local dt = { y = tonumber(y), m = tonumber(m), d = tonumber(d), h = 0, mi = 0, s = 0 }
  local h, mi, s, z = rest:match("^T(%d%d)(%d%d)(%d%d)(Z?)")
  if h then
    dt.h, dt.mi, dt.s = tonumber(h), tonumber(mi), tonumber(s)
    dt.utc = z == "Z"
    if not dt.utc and params and params.TZID then
      dt.tzid = params.TZID:gsub("^/", "")
    end
  else
    dt.date = true
  end
  return dt
end

local function day_of(dt)
  return util.days_from_civil(dt.y, dt.m, dt.d)
end

local function tod(dt)
  return dt.h * 3600 + dt.mi * 60 + dt.s
end

---"P1D", "PT1H30M", "-PT15M", "P1W" → seconds
function M.parse_duration(s)
  if not s then
    return nil
  end
  local sign, body = s:match("^([+-]?)P(.+)$")
  if not body then
    return nil
  end
  local total = 0
  local date, time = body:match("^([^T]*)T?(.*)$")
  for n, u in date:gmatch("(%d+)([WD])") do
    total = total + tonumber(n) * (u == "W" and 604800 or 86400)
  end
  for n, u in time:gmatch("(%d+)([HMS])") do
    total = total + tonumber(n) * (u == "H" and 3600 or u == "M" and 60 or 1)
  end
  return sign == "-" and -total or total
end

function M.parse_rrule(s)
  local r = { interval = 1, wkst = 1, unsupported = {} }
  for k, v in (s or ""):gmatch("([^=;]+)=([^;]*)") do
    k = k:upper()
    if k == "FREQ" then
      r.freq = v:upper()
    elseif k == "INTERVAL" then
      r.interval = math.max(1, tonumber(v) or 1)
    elseif k == "COUNT" then
      r.count = tonumber(v)
    elseif k == "UNTIL" then
      r["until"] = M.parse_dt(v)
    elseif k == "WKST" then
      r.wkst = WD[v:upper()] or 1
    elseif k == "BYDAY" then
      r.byday = {}
      for item in v:gmatch("[^,]+") do
        local ord, wd = item:match("^([+-]?%d*)(%a%a)$")
        if wd and WD[wd:upper()] then
          r.byday[#r.byday + 1] = { ord = tonumber(ord), wd = WD[wd:upper()] }
        end
      end
    elseif k == "BYMONTHDAY" or k == "BYMONTH" then
      local list = {}
      for n in v:gmatch("[^,]+") do
        list[#list + 1] = tonumber(n)
      end
      r[k:lower()] = list
    else
      r.unsupported[#r.unsupported + 1] = k
    end
  end
  if not FREQS[r.freq or ""] then
    r.unsupported[#r.unsupported + 1] = "FREQ=" .. tostring(r.freq)
  end
  return r
end

---Parse calendar text → { name?, tz?, events = { ev... } }
---ev = { uid, summary, location, description, conference, status, transp, dtstart, dtend?, duration?,
---       rrule?, exdate = {dt...}, rdate = {dt...}, recurrence_id?, attendees = {{email, partstat}} }
function M.parse(text)
  local cal = { events = {} }
  local ev, depth = nil, 0
  for line in M.unfold(text):gmatch("[^\n]+") do
    local name, params, value = M.parse_line(line)
    if name == "BEGIN" then
      if value == "VEVENT" and not ev then
        ev = { exdate = {}, rdate = {}, attendees = {} }
        depth = 0
      elseif ev then
        depth = depth + 1 -- VALARM etc.
      end
    elseif name == "END" then
      if ev and depth > 0 then
        depth = depth - 1
      elseif ev and value == "VEVENT" then
        if ev.dtstart then
          cal.events[#cal.events + 1] = ev
        end
        ev = nil
      end
    elseif ev and depth == 0 and name then
      if name == "UID" then
        ev.uid = value
      elseif name == "SUMMARY" then
        ev.summary = M.unescape(value)
      elseif name == "LOCATION" then
        ev.location = M.unescape(value)
      elseif name == "DESCRIPTION" then
        ev.description = M.unescape(value)
      elseif name == "X-GOOGLE-CONFERENCE" then
        ev.conference = value
      elseif name == "STATUS" then
        ev.status = value:upper()
      elseif name == "TRANSP" then
        ev.transp = value:upper()
      elseif name == "DTSTART" then
        ev.dtstart = M.parse_dt(value, params)
      elseif name == "DTEND" then
        ev.dtend = M.parse_dt(value, params)
      elseif name == "DURATION" then
        ev.duration = M.parse_duration(value)
      elseif name == "RRULE" then
        ev.rrule = M.parse_rrule(value)
      elseif name == "RECURRENCE-ID" then
        ev.recurrence_id = M.parse_dt(value, params)
      elseif MULTI[name] then
        if name == "ATTENDEE" then
          ev.attendees[#ev.attendees + 1] = {
            email = (value:match("^[Mm][Aa][Ii][Ll][Tt][Oo]:(.+)$") or value):lower(),
            partstat = params.PARTSTAT and params.PARTSTAT:upper(),
          }
        else
          for v in value:gmatch("[^,]+") do
            local dt = M.parse_dt(v, params)
            if dt then
              table.insert(ev[name:lower()], dt)
            end
          end
        end
      end
    elseif not ev and name == "X-WR-CALNAME" then
      cal.name = M.unescape(value)
    elseif not ev and name == "X-WR-TIMEZONE" then
      cal.tz = value
    end
  end
  return cal
end

-- Recurrence ------------------------------------------------------------------------

local function wday(D)
  return (D + 4) % 7 -- 0 = Sunday
end

local function ymd(D)
  local t = os.date("!*t", D * 86400)
  return t.year, t.month, t.day
end

local function days_in_month(y, m)
  local nxt = m == 12 and util.days_from_civil(y + 1, 1, 1) or util.days_from_civil(y, m + 1, 1)
  return nxt - util.days_from_civil(y, m, 1)
end

local function has(list, v)
  for _, x in ipairs(list) do
    if x == v then
      return true
    end
  end
  return false
end

local function has_wd(byday, wd)
  for _, b in ipairs(byday) do
    if b.wd == wd then
      return true
    end
  end
  return false
end

---BYMONTHDAY / BYDAY (with ordinals) / default day-of-month within a month.
local function month_match(r, D, y, m, d, sdt)
  local n = days_in_month(y, m)
  if r.bymonthday then
    local ok = false
    for _, md in ipairs(r.bymonthday) do
      if md == d or (md < 0 and n + md + 1 == d) then
        ok = true
      end
    end
    if not ok then
      return false
    end
  end
  if r.byday then
    local wd = wday(D)
    for _, b in ipairs(r.byday) do
      if b.wd == wd then
        if not b.ord or b.ord == 0 then
          return true
        elseif b.ord > 0 and math.floor((d - 1) / 7) + 1 == b.ord then
          return true
        elseif b.ord < 0 and math.floor((n - d) / 7) + 1 == -b.ord then
          return true
        end
      end
    end
    return false
  end
  return r.bymonthday ~= nil or d == sdt.d
end

---Does rule `r` (DTSTART day S, fields sdt) produce an occurrence on day D?
function M.matches(r, D, S, sdt)
  if D < S then
    return false
  end
  local y, m, d = ymd(D)
  if r.bymonth and not has(r.bymonth, m) then
    return false
  end
  local f = r.freq
  if f == "DAILY" then
    if (D - S) % r.interval ~= 0 then
      return false
    end
    if r.byday and not has_wd(r.byday, wday(D)) then
      return false
    end
    return not r.bymonthday or has(r.bymonthday, d)
  elseif f == "WEEKLY" then
    local function week(x)
      return math.floor((x - (r.wkst - 4)) / 7)
    end
    if (week(D) - week(S)) % r.interval ~= 0 then
      return false
    end
    return has_wd(r.byday or { { wd = wday(S) } }, wday(D))
  elseif f == "MONTHLY" then
    if ((y - sdt.y) * 12 + (m - sdt.m)) % r.interval ~= 0 then
      return false
    end
    return month_match(r, D, y, m, d, sdt)
  elseif f == "YEARLY" then
    if (y - sdt.y) % r.interval ~= 0 then
      return false
    end
    if not r.bymonth and m ~= sdt.m then
      return false
    end
    return month_match(r, D, y, m, d, sdt)
  end
  return false
end

---Is D within the first COUNT occurrences? (EXDATEs still count, per RFC 5545.)
local function within_count(r, D, S, sdt)
  if not r.count then
    return true
  end
  if D - S > 40000 then
    return false
  end
  local n = 0
  for x = S, D do
    if M.matches(r, x, S, sdt) then
      n = n + 1
      if n > r.count then
        return false
      end
    end
  end
  return true
end

-- Expansion -------------------------------------------------------------------------

local function find_link(ev)
  local pats = {
    "https://meet%.google%.com/[%w%-]+",
    "https://[%w%.%-]*zoom%.us/j/[%w%?=&%.%-]+",
    "https://teams%.microsoft%.com/l/meetup%-join/[^%s>\"]+",
    "https://[%w%.%-]*webex%.com/[^%s>\"]+",
  }
  local fields = { ev.conference or false, ev.location or false, ev.description or false }
  for _, field in ipairs(fields) do
    if field then
      for _, p in ipairs(pats) do
        local u = field:match(p)
        if u then
          return u
        end
      end
    end
  end
end

---Expand into occurrences overlapping UTC window [ws, we).
---`opts.zone`: display zone (all-day events and floating times); `opts.email`: whose PARTSTAT counts.
---Returns occurrences sorted by start:
---{ uid, title, start, stop, allday, link, location, declined, cancelled, warn? }
function M.expand(cal, ws, we, opts)
  opts = opts or {}
  local zone = opts.zone
  local floating = cal.tz and tz.known(cal.tz) and cal.tz or zone
  local email = opts.email and opts.email:lower()
  if not email and cal.name and cal.name:find("@") then
    email = cal.name:lower()
  end

  local function zone_of(dt)
    if dt.utc then
      return "UTC", nil
    elseif dt.date then
      return zone, nil
    elseif dt.tzid then
      if tz.known(dt.tzid) then
        return dt.tzid, nil
      end
      return floating, "unknown TZID " .. dt.tzid
    end
    return floating, nil
  end
  local function epoch(dt)
    local z = zone_of(dt)
    return tz.to_utc(z, day_of(dt) * 86400 + tod(dt))
  end

  -- RECURRENCE-ID overrides replace the master's instance at that original start.
  local overridden = {}
  for _, ev in ipairs(cal.events) do
    if ev.recurrence_id and ev.uid then
      overridden[ev.uid .. "@" .. epoch(ev.recurrence_id)] = true
    end
  end

  local out = {}
  local function emit(ev, st, en, warn)
    if st < we and (en > ws or (en == st and st >= ws)) then
      local declined = false
      if email then
        for _, a in ipairs(ev.attendees) do
          if a.email == email and a.partstat == "DECLINED" then
            declined = true
          end
        end
      end
      out[#out + 1] = {
        uid = ev.uid,
        title = ev.summary or "(no title)",
        start = st,
        stop = en,
        allday = ev.dtstart.date or false,
        link = find_link(ev),
        location = ev.location,
        declined = declined,
        cancelled = ev.status == "CANCELLED",
        free = ev.transp == "TRANSPARENT",
        warn = warn,
      }
    end
  end

  for _, ev in ipairs(cal.events) do
    local s = ev.dtstart
    local ezone, tzwarn = zone_of(s)
    local function length(st)
      if ev.dtend then
        return epoch(ev.dtend) - st
      elseif ev.duration then
        return ev.duration
      end
      return s.date and 86400 or 0
    end

    if ev.status == "CANCELLED" and not ev.recurrence_id then
      -- cancelled series/single: nothing to show
    elseif not ev.rrule or ev.recurrence_id then
      if ev.status ~= "CANCELLED" then
        local st = epoch(s)
        emit(ev, st, st + length(st), tzwarn)
      end
    else
      local r = ev.rrule
      local warn = tzwarn
      if #r.unsupported > 0 then
        warn = "unsupported recurrence: " .. table.concat(r.unsupported, ",")
      end
      local S = day_of(s)
      local base_len = length(epoch(s))
      local span = math.ceil(math.max(base_len, 0) / 86400)
      local d0 = math.floor(tz.wall(ezone, ws) / 86400) - 1 - span
      local d1 = math.floor(tz.wall(ezone, we) / 86400) + 1
      local until_t
      if r["until"] then
        local u = r["until"]
        until_t = u.date and tz.to_utc(ezone, (day_of(u) + 1) * 86400) - 1 or epoch(u)
      end
      local ex = {}
      for _, x in ipairs(ev.exdate) do
        ex[epoch(x)] = true
        if x.date then
          ex["d" .. day_of(x)] = true
        end
      end
      local function occurrence(st, D)
        if ex[st] or (D and ex["d" .. D]) then
          return
        end
        if ev.uid and overridden[ev.uid .. "@" .. st] then
          return
        end
        emit(ev, st, st + base_len, warn)
      end
      for D = math.max(d0, S), d1 do
        if M.matches(r, D, S, s) and within_count(r, D, S, s) then
          local st = tz.to_utc(ezone, D * 86400 + tod(s))
          if not until_t or st <= until_t then
            occurrence(st, D)
          end
        end
      end
      for _, rd in ipairs(ev.rdate) do
        occurrence(epoch(rd), rd.date and day_of(rd) or nil)
      end
    end
  end

  table.sort(out, function(a, b)
    if a.allday ~= b.allday then
      return a.allday
    end
    if a.start ~= b.start then
      return a.start < b.start
    end
    return a.title < b.title
  end)
  return out
end

M._has_wd = has_wd

return M
