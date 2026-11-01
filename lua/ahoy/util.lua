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

function M.has(exe)
  return vim.fn.executable(exe) == 1
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
