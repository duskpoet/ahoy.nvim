-- Time zones without dependencies: reads the system's TZif files (zoneinfo), including the POSIX
-- TZ footer used past the last transition (needed for "slim" zoneinfo builds).
--   zone = nil      → the configured `timezone`, else the system zone (/etc/localtime)
--   zone = "UTC"    → UTC
--   zone = "Area/City"
-- "wall" times are local seconds counted as if they were UTC (days_from_civil * 86400 + time).
local util = require("ahoy.util")

local M = {}

local cache = {}

local function u32(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  return ((a * 256 + b) * 256 + c) * 256 + d
end
local function i32(s, i)
  local v = u32(s, i)
  return v >= 2147483648 and v - 4294967296 or v
end
local function i64(s, i)
  return i32(s, i) * 4294967296 + u32(s, i + 4)
end

-- POSIX TZ strings ---------------------------------------------------------------

---Parse "[+-]hh[:mm[:ss]]" at `i`. Returns seconds, next index.
local function posix_time(s, i)
  local sign, h, rest = s:match("^([+-]?)(%d+)()", i)
  if not h then
    return nil, i
  end
  local secs = tonumber(h) * 3600
  i = rest
  local m, r2 = s:match("^:(%d+)()", i)
  if m then
    secs, i = secs + tonumber(m) * 60, r2
    local sec, r3 = s:match("^:(%d+)()", i)
    if sec then
      secs, i = secs + tonumber(sec), r3
    end
  end
  return sign == "-" and -secs or secs, i
end

local function posix_name(s, i)
  if s:sub(i, i) == "<" then
    local j = s:find(">", i, true)
    return j and j + 1 or nil
  end
  local j = s:match("^%a+()", i)
  return j
end

---Parse a POSIX TZ string ("CET-1CEST,M3.5.0,M10.5.0/3"). Returns
---{ std = utoff, dst? = utoff, start? = rule, ["end"]? = rule } with utoff in seconds east of UTC.
function M.parse_posix(s)
  if not s or s == "" then
    return nil
  end
  local i = posix_name(s, 1)
  if not i then
    return nil
  end
  local off
  off, i = posix_time(s, i)
  if not off then
    return nil
  end
  local z = { std = -off }
  if i > #s then
    return z
  end
  local j = posix_name(s, i)
  if not j then
    return z
  end
  i = j
  local doff
  doff, i = posix_time(s, i)
  z.dst = doff and -doff or z.std + 3600
  local function rule()
    local mo, w, d, r = s:match("^,M(%d+)%.(%d+)%.(%d+)()", i)
    if not mo then
      return nil
    end
    i = r
    local t = 7200
    if s:sub(i, i) == "/" then
      t, i = posix_time(s, i + 1)
    end
    return { m = tonumber(mo), w = tonumber(w), d = tonumber(d), t = t }
  end
  z.start = rule()
  z["end"] = rule()
  if not z.start or not z["end"] then
    z.dst = nil -- unsupported rule form (Jn / n): fall back to standard time
  end
  return z
end

---Wall seconds of rule `r` in year `y` (the local time at which the switch happens).
local function rule_wall(r, y)
  local first = util.days_from_civil(y, r.m, 1)
  local wd_first = (first + 4) % 7 -- 0 = Sunday
  local day = first + (r.d - wd_first) % 7 + (r.w - 1) * 7
  if r.w == 5 then
    local nm = r.m == 12 and util.days_from_civil(y + 1, 1, 1) or util.days_from_civil(y, r.m + 1, 1)
    while day >= nm do
      day = day - 7
    end
  end
  return day * 86400 + r.t
end

local function posix_offset(z, t)
  if not z.dst then
    return z.std
  end
  local y = os.date("!*t", t + z.std).year
  local s = rule_wall(z.start, y) - z.std -- DST starts at local standard time
  local e = rule_wall(z["end"], y) - z.dst -- ends at local daylight time
  if s < e then
    return (t >= s and t < e) and z.dst or z.std
  end
  return (t >= e and t < s) and z.std or z.dst -- southern hemisphere
end

-- TZif ---------------------------------------------------------------------------

function M.parse_tzif(s)
  if type(s) ~= "string" or s:sub(1, 4) ~= "TZif" then
    return nil
  end
  local ver = s:sub(5, 5)
  local function counts(p)
    return u32(s, p + 20), u32(s, p + 24), u32(s, p + 28), u32(s, p + 32), u32(s, p + 36), u32(s, p + 40)
  end
  local p, tsize = 1, 4
  local isut, isstd, leap, timecnt, typecnt, charcnt = counts(p)
  if ver >= "2" then
    p = p + 44 + timecnt * 5 + typecnt * 6 + charcnt + leap * 8 + isstd + isut
    isut, isstd, leap, timecnt, typecnt, charcnt = counts(p)
    tsize = 8
  end
  local q = p + 44
  local z = { times = {}, idx = {}, types = {} }
  for k = 1, timecnt do
    z.times[k] = tsize == 8 and i64(s, q) or i32(s, q)
    q = q + tsize
  end
  for k = 1, timecnt do
    z.idx[k] = s:byte(q) + 1
    q = q + 1
  end
  for k = 1, typecnt do
    z.types[k] = { off = i32(s, q), dst = s:byte(q + 4) == 1 }
    q = q + 6
  end
  q = q + charcnt + leap * (tsize + 4) + isstd + isut
  if ver >= "2" then
    z.footer = M.parse_posix(s:match("^\n([^\n]*)\n", q))
  end
  if #z.types == 0 then
    return nil
  end
  return z
end

local function zoneinfo_path(name)
  local dirs = { vim.env.TZDIR or "", "/usr/share/zoneinfo", "/usr/lib/zoneinfo", "/usr/share/lib/zoneinfo" }
  for _, d in ipairs(dirs) do
    if d and d ~= "" then
      local p = d .. "/" .. name
      if vim.fn.filereadable(p) == 1 then
        return p
      end
    end
  end
end

local function configured()
  local ok, ahoy = pcall(require, "ahoy")
  return ok and ahoy.config and ahoy.config.timezone or nil
end

---Load a zone (cached). Returns the zone table or nil if unknown.
function M.load(name)
  name = name or configured() or vim.env.TZ
  if name then
    name = name:gsub("^:", ""):gsub("^/+", "")
  end
  local key = name or "localtime"
  if cache[key] ~= nil then
    return cache[key] or nil
  end
  local z
  if name == "UTC" or name == "Etc/UTC" or name == "GMT" or name == "Z" then
    z = { utc = true }
  else
    local path
    if name then
      path = zoneinfo_path(name)
    else
      path = "/etc/localtime"
    end
    local f = path and io.open(path, "rb")
    if f then
      z = M.parse_tzif(f:read("*a"))
      f:close()
    end
    if not z and name then
      -- maybe a POSIX TZ string ("EST5EDT,M3.2.0,M11.1.0")
      local px = M.parse_posix(name)
      z = px and { times = {}, idx = {}, types = {}, footer = px } or nil
    end
  end
  cache[key] = z or false
  return z
end

function M.known(name)
  return M.load(name) ~= nil
end

---UTC offset (seconds east) of zone `name` at UTC time `t`.
function M.offset(name, t)
  local z = M.load(name)
  if not z then
    -- unknown: system local via os.date
    local u = os.date("!*t", t)
    u.isdst = false
    local l = os.date("*t", t)
    l.isdst = false
    return os.time(l) - os.time(u)
  end
  if z.utc then
    return 0
  end
  local n = #z.times
  if n == 0 or t < z.times[1] then
    if n == 0 and z.footer then
      return posix_offset(z.footer, t)
    end
    for _, ty in ipairs(z.types) do
      if not ty.dst then
        return ty.off
      end
    end
    return z.types[1].off
  end
  if t >= z.times[n] and z.footer then
    return posix_offset(z.footer, t)
  end
  local lo, hi = 1, n
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if z.times[mid] <= t then
      lo = mid
    else
      hi = mid - 1
    end
  end
  return z.types[z.idx[lo]].off
end

---Wall time (local seconds, UTC-based arithmetic) for UTC `t` in zone `name`.
function M.wall(name, t)
  return t + M.offset(name, t)
end

---UTC time for wall time `wall` in zone `name` (gaps resolve forward, overlaps to the first).
function M.to_utc(name, wall)
  local o1 = M.offset(name, wall - M.offset(name, wall))
  local t = wall - o1
  local o2 = M.offset(name, t)
  if o2 ~= o1 then
    t = wall - o2
    if M.offset(name, t) ~= o2 then
      t = wall - math.max(o1, o2) -- in a gap: pick the later instant
    end
  end
  return t
end

---os.date-style formatting of UTC `t` in zone `name` (no %Z/%z).
function M.strftime(fmt, t, name)
  return os.date("!" .. fmt, M.wall(name, t))
end

---Day number (days since 1970-01-01 in the zone) containing UTC `t`.
function M.day(name, t)
  return math.floor(M.wall(name, t) / 86400)
end

---UTC bounds [start, end) of the zone-local day containing `t`.
function M.day_bounds(name, t)
  local d = M.day(name, t)
  return M.to_utc(name, d * 86400), M.to_utc(name, (d + 1) * 86400)
end

function M._clear()
  cache = {}
end

return M
