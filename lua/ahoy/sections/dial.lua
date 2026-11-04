-- Quick dial: user-configured actions (`config.dial`), each on a row (<CR>) and an optional
-- dashboard-wide key. Hidden when nothing is configured or nothing applies to the context.
local actions = require("ahoy.actions")
local ui = require("ahoy.ghui")

local M = {}

local function cfg_actions()
  local ok, ahoy = pcall(require, "ahoy")
  return ok and ahoy.config and ahoy.config.dial or {}
end

---Configured actions whose `when(ctx)` passes. When several share a key, only the first keeps
---it (the rest are shown without one), so the card matches what the key does.
function M.visible(ctx)
  local out, taken = {}, {}
  for _, a in ipairs(cfg_actions()) do
    local ok, r = true, true
    if a.when then
      ok, r = pcall(a.when, ctx)
    end
    if ok and r then
      if a.key and taken[a.key] then
        a = vim.tbl_extend("force", a, { key = false })
      elseif a.key then
        taken[a.key] = true
      end
      out[#out + 1] = a
    end
  end
  return out
end

---The visible action bound to dashboard key `key`, if any.
function M.by_key(key, ctx)
  for _, a in ipairs(M.visible(ctx)) do
    if a.key == key then
      return a
    end
  end
end

local function subst(s, input)
  return (s:gsub("{input}", function()
    return input or ""
  end))
end

local function exec(a, ctx, input)
  if a.run then
    return a.run(ctx, input)
  elseif a.cmd then
    return vim.cmd(subst(a.cmd, input))
  elseif a.harner then
    local p = a.harner
    if type(p) == "function" then
      p = p(ctx, input)
    else
      p = subst(p, input)
    end
    return actions.harner(p)
  end
end

local function safe_exec(a, ctx, input)
  local ok, err = pcall(exec, a, ctx, input)
  if not ok then
    vim.notify("ahoy: " .. tostring(err), vim.log.levels.ERROR)
  end
end

---Run action `a`, asking for `a.input` first when set (cancel aborts; empty input is passed as "").
---Errors are reported as notifications whichever way it was triggered (row <CR> or dial key).
function M.run(a, ctx)
  if not a.input then
    return safe_exec(a, ctx)
  end
  vim.ui.input({ prompt = a.input }, function(input)
    if input ~= nil then
      safe_exec(a, ctx, vim.trim(input))
    end
  end)
end

local function key_label(a)
  return a.key and ("[" .. a.key .. "]") or "   "
end

M.name = "dial"
M.title = "Quick dial"
M.slots = { "card", "ticker", "hero" }
M.wide = true -- a short full-width row; keeps the other cards' two-up pairing intact
M.timeout = false

function M.when(ctx)
  return #M.visible(ctx) > 0
end

function M.fetch(ctx, done)
  local list = M.visible(ctx)
  done(#list > 0 and list or nil)
end

function M.render(list, slot, width)
  if slot == "ticker" then
    local segs = {}
    for i, a in ipairs(list) do
      if i > 1 then
        segs[#segs + 1] = { "   " }
      end
      if a.key then
        segs[#segs + 1] = { a.key .. " ", "AhoyKey" }
      end
      segs[#segs + 1] = { a.label or "?" }
    end
    return { lines = { segs } }
  end
  local b = ui.builder(width)
  for _, a in ipairs(list) do
    b:add({ { key_label(a) .. " ", "AhoyKey" }, { a.label or "?" } }, a.desc, {
      [actions.keys().open] = function(ctx)
        M.run(a, ctx)
      end,
    })
  end
  return b:result()
end

return M
