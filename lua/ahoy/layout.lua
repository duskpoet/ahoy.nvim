local M = {}

local function list(v)
  if v == nil then
    return {}
  elseif type(v) == "string" then
    return { v }
  end
  return v
end

---Resolve a layout spec against the configured sections and the context.
---Unknown sections, sections that don't support the slot, and sections whose
---`when(ctx)` is falsy are dropped.
---Returns { header?, hero = {...}, tickers = {...}, cards = {...}, names = {...unique, in order} }
function M.resolve(layout, sections, ctx, cfg)
  layout = layout or {}
  local plan = { hero = {}, tickers = {}, cards = {}, names = {} }
  local seen = {}

  local function usable(name, slot)
    if name == "idle" and cfg and cfg.idle == false then
      return false
    end
    local s = sections[name]
    if not s then
      return false
    end
    if s.slots and not vim.tbl_contains(s.slots, slot) then
      return false
    end
    if s.when then
      local ok, r = pcall(s.when, ctx)
      if not ok or not r then
        return false
      end
    end
    return true
  end

  local function add(name)
    if not seen[name] then
      seen[name] = true
      plan.names[#plan.names + 1] = name
    end
  end

  for _, n in ipairs(list(layout.header)) do
    if usable(n, "header") then
      plan.header = n
      add(n)
      break
    end
  end
  for key, slot in pairs({ hero = "hero", tickers = "ticker", cards = "card" }) do
    for _, n in ipairs(list(layout[key])) do
      if usable(n, slot) then
        table.insert(plan[key], n)
      end
    end
  end
  -- Stable fetch order: header, hero, tickers, cards.
  for _, key in ipairs({ "hero", "tickers", "cards" }) do
    for _, n in ipairs(plan[key]) do
      add(n)
    end
  end

  return plan
end

return M
