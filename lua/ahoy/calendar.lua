-- Calendar source: private ICS feed → today's occurrences (shared by next_meeting / calendar).
-- The URL is a secret: read from a file (never setup()), passed to curl on stdin (not argv,
-- which other users could see in `ps`), and never shown or logged.
local util = require("ahoy.util")
local ics = require("ahoy.ics")
local tz = require("ahoy.tz")

local M = {}

local function cfg()
  local ok, ahoy = pcall(require, "ahoy")
  local c = ok and ahoy.config and ahoy.config.calendar
  return c or require("ahoy.config").defaults.calendar
end
M.cfg = cfg

function M.url_file()
  return vim.fn.expand(cfg().url_file)
end

function M.configured()
  return vim.fn.filereadable(M.url_file()) == 1
end

---Display zone name (nil = system).
function M.zone()
  local ok, ahoy = pcall(require, "ahoy")
  return ok and ahoy.config and ahoy.config.timezone or nil
end

function M.fmt(t, fmt)
  return tz.strftime(fmt or "%H:%M", t, M.zone())
end

---Read the URL and check permissions. Returns url, warning?, err?
function M.read_url(path)
  path = path or M.url_file()
  local f = io.open(path, "r")
  if not f then
    return nil, nil, "can't read " .. vim.fn.fnamemodify(path, ":~")
  end
  local text = f:read("*a") or ""
  f:close()
  local url = vim.trim(text):match("^(%S+)")
  url = url and (url:gsub("^webcals?://", "https://"))
  if not url or not url:match("^https?://") then
    return nil, nil, vim.fn.fnamemodify(path, ":~") .. " doesn't contain an http(s) URL"
  end
  local warn
  local st = util.uv.fs_stat(path)
  if st and st.mode % 64 ~= 0 then -- any group/other bits
    warn = ("%s is mode %o; run chmod 600"):format(vim.fn.fnamemodify(path, ":~"), st.mode % 512)
  end
  return url, warn
end

---Build today's model from ICS text.
function M.build(text, now, extra_warnings)
  local zone = M.zone()
  local ok, cal = pcall(ics.parse, text)
  if not ok then
    return nil, "parse: " .. tostring(cal)
  end
  local ws, we = tz.day_bounds(zone, now)
  local ok2, occ = pcall(ics.expand, cal, ws, we, { zone = zone, email = cfg().email })
  if not ok2 then
    return nil, "expand: " .. tostring(occ)
  end
  local warnings = vim.deepcopy(extra_warnings or {})
  local n_warn = 0
  for _, o in ipairs(occ) do
    if o.warn then
      n_warn = n_warn + 1
    end
  end
  if n_warn > 0 then
    warnings[#warnings + 1] = ("%d event%s with partly unsupported recurrence/timezone"):format(n_warn,
      n_warn == 1 and "" or "s")
  end
  local events = {}
  for _, o in ipairs(occ) do
    if not o.cancelled then
      events[#events + 1] = o
    end
  end
  return { events = events, fetched = now, day_start = ws, day_end = we, warnings = warnings, name = cal.name }
end

local function fetch(finish)
  local url, warn, err = M.read_url()
  if not url then
    return finish(nil, err)
  end
  if not util.has("curl") then
    return finish(nil, "curl not found")
  end
  local conf = ('url = "%s"\n'):format(url:gsub("\\", "\\\\"):gsub('"', '\\"'))
  util.run(
    { "curl", "-fsS", "-L", "--compressed", "--max-time", "20", "-K", "-" },
    { stdin = conf, timeout = 25000 },
    function(r)
      if r.code ~= 0 then
        local msg = vim.trim(r.stderr or "")
        -- curl only names the host, but be safe: never echo anything URL-shaped
        msg = msg:gsub("https?://%S+", "<feed>")
        return finish(nil, msg ~= "" and msg or ("curl exited with %d"):format(r.code))
      end
      local body = r.stdout or ""
      if not body:find("BEGIN:VCALENDAR", 1, true) then
        return finish(nil, "feed didn't return iCalendar data (check the URL)")
      end
      local model, e = M.build(body, os.time(), warn and { warn } or nil)
      finish(model, e)
    end
  )
end

---Today's model, fetched once per dashboard refresh. `cb(model, err)`
---model = { events = {occ...}, fetched, day_start, day_end, warnings = {string...} }
function M.today(ctx, cb)
  util.shared(ctx, "calendar", fetch, cb)
end

-- Helpers for rendering --------------------------------------------------------------

---Timed events that count as meetings (not all-day, declined, cancelled or "free").
function M.meetings(model)
  local out = {}
  for _, e in ipairs(model.events) do
    if not e.allday and not e.declined and not e.free then
      out[#out + 1] = e
    end
  end
  return out
end

---Current (possibly several) and upcoming meetings at `now`.
function M.split(model, now)
  local cur, nxt = {}, {}
  for _, e in ipairs(M.meetings(model)) do
    if e.start <= now and now < e.stop then
      cur[#cur + 1] = e
    elseif e.start > now then
      nxt[#nxt + 1] = e
    end
  end
  return cur, nxt
end

---"12m", "2h 05m"
function M.countdown(secs)
  local m = math.max(0, math.ceil(secs / 60))
  if m < 60 then
    return m .. "m"
  end
  return ("%dh %02dm"):format(math.floor(m / 60), m % 60)
end

---Short label for a meeting link.
function M.link_label(url)
  if not url then
    return nil
  end
  if url:find("meet.google.com", 1, true) then
    return "Meet"
  elseif url:find("zoom.us", 1, true) then
    return "Zoom"
  elseif url:find("teams.microsoft.com", 1, true) then
    return "Teams"
  elseif url:find("webex.com", 1, true) then
    return "Webex"
  end
  return "link"
end

return M
