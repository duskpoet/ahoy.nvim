local M = {}

M.uv = vim.uv or vim.loop

---Display width of a string.
function M.width(s)
  return vim.fn.strdisplaywidth(s)
end

---Total display width of a list of `{ text, hl }` segments.
function M.segs_width(segs)
  local w = 0
  for _, s in ipairs(segs) do
    w = w + M.width(s[1])
  end
  return w
end

---Longest prefix of `s` whose display width is <= n.
function M.take(s, n)
  if n <= 0 then
    return ""
  end
  if M.width(s) <= n then
    return s
  end
  local out, acc = {}, 0
  for _, ch in ipairs(vim.fn.split(s, "\\zs")) do
    local cw = M.width(ch)
    if acc + cw > n then
      break
    end
    out[#out + 1] = ch
    acc = acc + cw
  end
  return table.concat(out)
end

---Truncate to display width `w`, ending with "…" if cut.
function M.truncate(s, w)
  if w <= 0 then
    return ""
  end
  if M.width(s) <= w then
    return s
  end
  return M.take(s, w - 1) .. "…"
end

function M.fmt_ms(ms)
  if not ms then
    return ""
  end
  if ms < 1000 then
    return string.format("%dms", ms)
  end
  return string.format("%.1fs", ms / 1000)
end

---Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's days_from_civil).
local function days_from_civil(y, m, d)
  y = m <= 2 and y - 1 or y
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end
M.days_from_civil = days_from_civil

---Parse an ISO-8601 UTC timestamp ("2026-10-31T13:14:23Z") to epoch seconds. nil if unparseable.
function M.iso_to_epoch(s)
  if type(s) ~= "string" then
    return nil
  end
  local y, mo, d, h, mi, se = s:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then
    return nil
  end
  local t = days_from_civil(tonumber(y), tonumber(mo), tonumber(d)) * 86400
    + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(se)
  local sign, oh, om = s:match("([+-])(%d%d):?(%d%d)$")
  if sign then
    local off = (tonumber(oh) * 3600 + tonumber(om) * 60) * (sign == "+" and 1 or -1)
    t = t - off
  end
  return t
end

---Compact relative age: "now", "5m", "3h", "2d", "3w", "4mo", "2y".
function M.ago(epoch, now)
  if not epoch then
    return ""
  end
  local s = math.max(0, (now or os.time()) - epoch)
  if s < 60 then
    return "now"
  elseif s < 3600 then
    return math.floor(s / 60) .. "m"
  elseif s < 86400 then
    return math.floor(s / 3600) .. "h"
  elseif s < 86400 * 14 then
    return math.floor(s / 86400) .. "d"
  elseif s < 86400 * 60 then
    return math.floor(s / (86400 * 7)) .. "w"
  elseif s < 86400 * 365 then
    return math.floor(s / (86400 * 30)) .. "mo"
  end
  return math.floor(s / (86400 * 365)) .. "y"
end

function M.has(exe)
  return vim.fn.executable(exe) == 1
end

-- One producer run per (owner table, key), fanned out to every waiter. The dashboard passes
-- its ctx (recreated on each refresh), so sections sharing a source cause one fetch.
local shared_runs = setmetatable({}, { __mode = "k" })

---`start(finish)` runs once per (owner, key); `finish(...)` settles it; `cb(...)` gets the result
---(scheduled if already settled).
function M.shared(owner, key, start, cb)
  shared_runs[owner] = shared_runs[owner] or {}
  local e = shared_runs[owner][key]
  if e then
    if e.done then
      return vim.schedule(function()
        cb(unpack(e.res, 1, e.res.n))
      end)
    end
    return table.insert(e.waiters, cb)
  end
  e = { waiters = { cb } }
  shared_runs[owner][key] = e
  start(function(...)
    if e.done then
      return
    end
    e.done, e.res = true, { n = select("#", ...), ... }
    for _, w in ipairs(e.waiters) do
      w(...)
    end
  end)
end

---Async command. `cb(res)` runs on the main loop with `res = { code, stdout, stderr, ms }`.
---Never throws: a missing executable yields `code = -1`.
function M.run(cmd, opts, cb)
  opts = opts or {}
  local start = M.uv.hrtime()
  local ok, err = pcall(vim.system, cmd, {
    text = true,
    cwd = opts.cwd,
    env = opts.env,
    stdin = opts.stdin,
    timeout = opts.timeout or 15000,
  }, function(res)
    res.ms = (M.uv.hrtime() - start) / 1e6
    vim.schedule(function()
      cb(res)
    end)
  end)
  if not ok then
    vim.schedule(function()
      cb({ code = -1, stdout = "", stderr = tostring(err), ms = 0 })
    end)
  end
end

return M
