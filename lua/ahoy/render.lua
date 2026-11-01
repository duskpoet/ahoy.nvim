local util = require("ahoy.util")

local M = {}

M.ns = vim.api.nvim_create_namespace("ahoy")

-- Every group is a default link, so colorschemes (Nord by default) can override them.
local links = {
  AhoyTitle = "Title",
  AhoyHeroTitle = "Function",
  AhoyBorder = "Comment",
  AhoyDim = "Comment",
  AhoyKey = "Special",
  AhoyOk = "DiagnosticOk",
  AhoyWarn = "DiagnosticWarn",
  AhoyError = "DiagnosticError",
  AhoyInfo = "DiagnosticInfo",
  AhoyAccent = "Identifier",
  AhoyPath = "Directory",
  AhoyBranch = "Constant",
  AhoySpinner = "DiagnosticInfo",
  AhoyTiming = "NonText",
}

function M.setup_highlights()
  for k, v in pairs(links) do
    vim.api.nvim_set_hl(0, k, { link = v, default = true })
  end
end

local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
function M.spinner()
  return frames[math.floor(util.uv.hrtime() / 1e8) % #frames + 1]
end

-- Segments ------------------------------------------------------------------

---Convert a string + byte-range highlights `{ {s, e, group}, ... }` into segments.
local function to_segs(line, hls)
  if type(line) == "table" then
    return line
  end
  line = tostring(line)
  if not hls or #hls == 0 then
    return { { line } }
  end
  local cuts = { [0] = true, [#line] = true }
  for _, h in ipairs(hls) do
    cuts[math.max(0, math.min(h[1], #line))] = true
    cuts[math.max(0, math.min(h[2], #line))] = true
  end
  local pts = vim.tbl_keys(cuts)
  table.sort(pts)
  local segs = {}
  for i = 1, #pts - 1 do
    local a, b = pts[i], pts[i + 1]
    local g
    for _, h in ipairs(hls) do
      if h[1] <= a and h[2] >= b then
        g = h[3]
      end
    end
    segs[#segs + 1] = { line:sub(a + 1, b), g }
  end
  return segs
end

---Fit segments to display width `w`: truncate with "…", pad with spaces unless `nopad`.
local function fit(segs, w, nopad)
  if w <= 0 then
    return {}
  end
  local out, used = {}, 0
  local total = util.segs_width(segs)
  if total <= w then
    for _, s in ipairs(segs) do
      out[#out + 1] = s
    end
    used = total
  else
    for _, s in ipairs(segs) do
      local sw = util.width(s[1])
      if used + sw <= w - 1 then
        out[#out + 1] = s
        used = used + sw
      else
        local t = util.take(s[1], w - 1 - used)
        out[#out + 1] = { t .. "…", s[2] }
        used = used + util.width(t) + 1
        break
      end
    end
  end
  if not nopad and used < w then
    out[#out + 1] = { string.rep(" ", w - used) }
  end
  return out
end
M.fit = fit

-- Section bodies ------------------------------------------------------------

local function title_of(spec)
  return spec.title or spec.name
end

---Body rows `{ segs, keys? }` for a section in a slot, at inner width `w`, capped at `max` rows.
local function body(spec, st, slot, w, max)
  local rows
  if st.status == "loading" then
    rows = { { segs = { { "loading…", "AhoyDim" } } } }
  elseif st.status == "empty" then
    rows = { { segs = { { spec.empty or "nothing here", "AhoyDim" } } } }
  elseif st.status == "error" then
    rows = {}
    for l in tostring(st.err):gmatch("[^\n]+") do
      rows[#rows + 1] = { segs = { { (#rows == 0 and "✗ " or "  ") .. l, "AhoyError" } } }
      if #rows >= 3 then
        break
      end
    end
    if #rows == 0 then
      rows = { { segs = { { "✗ error", "AhoyError" } } } }
    end
  else
    local ok, res = pcall(spec.render, st.data, slot, w)
    if not ok then
      rows = { { segs = { { "✗ render: " .. tostring(res), "AhoyError" } } } }
    else
      res = res or {}
      local lines = res.lines or res
      local by_row = {}
      for _, h in ipairs(res.highlights or {}) do
        local r = h[1]
        by_row[r] = by_row[r] or {}
        table.insert(by_row[r], { h[2], h[3] < 0 and math.huge or h[3], h[4] })
      end
      rows = {}
      for i, l in ipairs(lines) do
        rows[i] = { segs = to_segs(l, by_row[i]), keys = res.keymaps and res.keymaps[i] }
      end
    end
  end
  if max and #rows > max then
    local extra = #rows - max + 1
    rows = vim.list_slice(rows, 1, max - 1)
    rows[#rows + 1] = { segs = { { ("… %d more"):format(extra), "AhoyDim" } } }
  end
  return rows
end

---Box a section: returns frags `{ segs, keys? }`, one per output row, all of display width W.
local function box(spec, st, rows, W, height, hero, spin)
  local inner = W - 4
  local title = {}
  if st.status == "loading" then
    title[#title + 1] = { spin .. " ", "AhoySpinner" }
  elseif st.status == "error" then
    title[#title + 1] = { "✗ ", "AhoyError" }
  end
  title[#title + 1] = { title_of(spec), hero and "AhoyHeroTitle" or "AhoyTitle" }
  title = fit(title, W - 6, true)
  local tw = util.segs_width(title)

  local out = {}
  local top = { { "╭─ ", "AhoyBorder" } }
  vim.list_extend(top, title)
  top[#top + 1] = { " " .. string.rep("─", W - 5 - tw) .. "╮", "AhoyBorder" }
  out[1] = { segs = top }
  for i = 1, height do
    local r = rows[i] or { segs = {} }
    local segs = { { "│ ", "AhoyBorder" } }
    vim.list_extend(segs, fit(r.segs, inner))
    segs[#segs + 1] = { " │", "AhoyBorder" }
    out[#out + 1] = { segs = segs, keys = r.keys }
  end
  out[#out + 1] = { segs = { { "╰" .. string.rep("─", W - 2) .. "╯", "AhoyBorder" } } }
  return out
end

-- Drawing -------------------------------------------------------------------

local function new_row()
  return { parts = {}, len = 0, hls = {}, regions = {} }
end

local function push(row, text, hl)
  local s = row.len
  row.parts[#row.parts + 1] = text
  row.len = row.len + #text
  if hl and #text > 0 then
    row.hls[#row.hls + 1] = { s, row.len, hl }
  end
end

---Draw the dashboard into `buf`. Returns `regions` (per line: `{ {col_s, col_e, keys}, ... }`)
---and the set of keys used by any region.
function M.draw(buf, win, S, cfg)
  local g = cfg.grid
  local secs = cfg.sections
  local ww = vim.api.nvim_win_get_width(win)
  local margin = ww < g.compact and 1 or 2
  local cw = math.max(20, math.min(ww - 2 * margin, g.max_width))
  local pad = string.rep(" ", math.max(0, math.floor((ww - cw) / 2)))
  local spin = M.spinner()
  local rows, keys_used = {}, {}

  local function line(frags)
    local r = new_row()
    push(r, pad)
    for _, f in ipairs(frags) do
      local s = r.len
      for _, sg in ipairs(f.segs) do
        push(r, sg[1], sg[2])
      end
      if f.keys then
        r.regions[#r.regions + 1] = { s, r.len, f.keys }
        for k in pairs(f.keys) do
          keys_used[k] = true
        end
      end
    end
    rows[#rows + 1] = r
  end
  local function blank()
    rows[#rows + 1] = new_row()
  end
  local function st_of(name)
    return S.states[name] or { status = "loading" }
  end

  blank()
  if not S.ctx then
    line({ { segs = { { spin .. " ", "AhoySpinner" }, { "detecting context…", "AhoyDim" } } } })
  else
    local plan = S.plan
    local shown = false

    -- header
    if plan.header then
      local spec, st = secs[plan.header], st_of(plan.header)
      if st.status == "loading" then
        line({ { segs = { { spin .. " ", "AhoySpinner" }, { title_of(spec), "AhoyDim" } } } })
        blank()
      elseif st.status ~= "empty" then
        for _, r in ipairs(body(spec, st, "header", cw, 2)) do
          line({ { segs = fit(r.segs, cw, true), keys = r.keys } })
        end
        blank()
      end
    end

    -- hero: first candidate that is loading or has data; errors only if nothing else
    local hero, first_err
    for _, n in ipairs(plan.hero) do
      local st = st_of(n)
      if st.status == "loading" or st.status == "ok" then
        hero = n
        break
      elseif st.status == "error" and not first_err then
        first_err = n
      end
    end
    hero = hero or first_err
    if hero then
      local spec, st = secs[hero], st_of(hero)
      local rows_ = body(spec, st, "hero", cw - 4, g.hero_max_lines)
      for _, f in ipairs(box(spec, st, rows_, cw, #rows_, true, spin)) do
        line({ f })
      end
      blank()
      shown = true
    end

    -- tickers
    local any_ticker = false
    for _, n in ipairs(plan.tickers) do
      local spec, st = secs[n], st_of(n)
      if st.status ~= "empty" then
        local segs = { { "▸ ", "AhoyAccent" } }
        if st.status == "loading" then
          segs[#segs + 1] = { spin .. " ", "AhoySpinner" }
        end
        segs[#segs + 1] = { title_of(spec) .. "  ", "AhoyTitle" }
        local keys
        if st.status ~= "loading" then
          local b = body(spec, st, "ticker", cw - util.segs_width(segs), 1)
          if b[1] then
            vim.list_extend(segs, b[1].segs)
            keys = b[1].keys
          end
        end
        line({ { segs = fit(segs, cw, true), keys = keys } })
        any_ticker = true
      end
    end
    if any_ticker then
      blank()
      shown = true
    end

    -- cards
    local cards = plan.cards
    local two = ww >= g.two_columns
    local i = 1
    while i <= #cards do
      if two and cards[i + 1] then
        local w1 = math.floor((cw - 2) / 2)
        local w2 = cw - 2 - w1
        local a, b = cards[i], cards[i + 1]
        local ra = body(secs[a], st_of(a), "card", w1 - 4, g.card_max_lines)
        local rb = body(secs[b], st_of(b), "card", w2 - 4, g.card_max_lines)
        local h = math.max(#ra, #rb)
        local fa = box(secs[a], st_of(a), ra, w1, h, false, spin)
        local fb = box(secs[b], st_of(b), rb, w2, h, false, spin)
        for k = 1, #fa do
          line({ fa[k], { segs = { { "  " } } }, fb[k] })
        end
        i = i + 2
      else
        local n = cards[i]
        local r = body(secs[n], st_of(n), "card", cw - 4, g.card_max_lines)
        for _, f in ipairs(box(secs[n], st_of(n), r, cw, #r, false, spin)) do
          line({ f })
        end
        i = i + 1
      end
      blank()
      shown = true
    end

    if not shown then
      line({ { segs = { { ("No sections for context '%s' yet. Configure `layouts` in setup()."):format(S.ctx.kind), "AhoyDim" } } } })
      blank()
    end
  end

  -- footer: legend + per-source timings
  local leg = {}
  for _, kv in ipairs({
    { cfg.keys.open, "open" },
    { cfg.keys.browser, "browser" },
    { cfg.keys.refresh, "refresh" },
    { cfg.keys.quit, "quit" },
  }) do
    if #leg > 0 then
      leg[#leg + 1] = { "   " }
    end
    leg[#leg + 1] = { kv[1], "AhoyKey" }
    leg[#leg + 1] = { " " .. kv[2], "AhoyDim" }
  end
  if S.ctx then
    local label = S.ctx.kind .. (S.ctx.pr and (" #" .. S.ctx.pr.number) or "")
    local gap = cw - util.segs_width(leg) - util.width(label)
    if gap >= 2 then
      leg[#leg + 1] = { string.rep(" ", gap) }
      leg[#leg + 1] = { label, "AhoyAccent" }
    end
  end
  line({ { segs = fit(leg, cw, true) } })

  if S.plan and #S.plan.names > 0 then
    local t = {}
    for _, n in ipairs(S.plan.names) do
      local st = st_of(n)
      if #t > 0 then
        t[#t + 1] = { " · ", "AhoyTiming" }
      end
      if st.status == "loading" then
        t[#t + 1] = { spin .. " " .. n, "AhoySpinner" }
      elseif st.status == "error" then
        t[#t + 1] = { n .. " ✗ " .. util.fmt_ms(st.ms), "AhoyError" }
      else
        t[#t + 1] = { n .. " " .. util.fmt_ms(st.ms), "AhoyTiming" }
      end
    end
    line({ { segs = fit(t, cw, true) } })
  end

  -- flush
  local lines, regions = {}, {}
  for idx, r in ipairs(rows) do
    lines[idx] = table.concat(r.parts)
    regions[idx] = r.regions
  end
  local cursor = vim.api.nvim_win_get_cursor(win)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  for idx, r in ipairs(rows) do
    for _, h in ipairs(r.hls) do
      vim.api.nvim_buf_set_extmark(buf, M.ns, idx - 1, h[1], { end_col = h[2], hl_group = h[3] })
    end
  end
  cursor[1] = math.min(cursor[1], #lines)
  pcall(vim.api.nvim_win_set_cursor, win, cursor)

  return regions, keys_used
end

return M
