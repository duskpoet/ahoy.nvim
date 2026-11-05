local config = require("ahoy.config")
local context = require("ahoy.context")
local layout = require("ahoy.layout")
local render = require("ahoy.render")
local section = require("ahoy.section")
local uv = require("ahoy.util").uv

local M = {}

---Dashboard state (exposed for tests/debugging).
local S = { gen = 0, states = {}, mapped = {}, regions = {} }
M._state = S

local function cfg()
  if not M.config then
    M.config = config.setup({})
    render.setup_highlights()
  end
  return M.config
end

local function valid()
  return S.buf ~= nil and vim.api.nvim_buf_is_valid(S.buf)
end

local function busy()
  if not S.ctx then
    return true
  end
  for _, st in pairs(S.states) do
    if st.status == "loading" then
      return true
    end
  end
  return false
end

local function builtin(key)
  local k = cfg().keys
  if key == k.quit then
    return M.close
  elseif key == k.refresh then
    return M.refresh
  end
  -- Quick dial: only the actions currently shown (their `when` passed for this context).
  if S.ctx and S.plan and vim.tbl_contains(S.plan.names, "dial") then
    local dial = require("ahoy.sections.dial")
    local a = dial.by_key(key, S.ctx)
    if a then
      return function()
        dial.run(a, S.ctx)
      end
    end
  end
end

---Run the action for `key` on the row under the cursor, else the built-in for that key.
local function dispatch(key)
  local cur = vim.api.nvim_win_get_cursor(0)
  local regs = S.regions[cur[1]] or {}
  local fn
  for _, r in ipairs(regs) do
    if r[3][key] and cur[2] >= r[1] and cur[2] < r[2] then
      fn = r[3][key]
    end
  end
  if not fn then
    local cands = vim.tbl_filter(function(r)
      return r[3][key] ~= nil
    end, regs)
    if #cands == 1 then
      fn = cands[1][3][key]
    end
  end
  if fn then
    local ok, err = pcall(fn, S.ctx)
    if not ok then
      vim.notify("ahoy: " .. tostring(err), vim.log.levels.ERROR)
    end
    return
  end
  local b = builtin(key)
  if b then
    b()
  end
end

local function map(key)
  if S.mapped[key] or not valid() then
    return
  end
  S.mapped[key] = true
  vim.keymap.set("n", key, function()
    dispatch(key)
  end, { buffer = S.buf, nowait = true, silent = true, desc = "ahoy: " .. key })
end

function M.render()
  if not valid() then
    return
  end
  local win = vim.fn.bufwinid(S.buf)
  if win == -1 then
    return
  end
  local regions, keys = render.draw(S.buf, win, S, cfg())
  S.regions = regions
  for k in pairs(keys) do
    map(k)
  end
end

local function stop_timer(name)
  local t = S[name]
  if t then
    t:stop()
    if not t:is_closing() then
      t:close()
    end
    S[name] = nil
  end
end

local function ensure_spinner()
  if not S.spin then
    S.spin = uv.new_timer()
  end
  if S.spin:is_active() then
    return
  end
  S.spin:start(100, 100, vim.schedule_wrap(function()
    if not valid() or not busy() then
      if S.spin then
        S.spin:stop()
      end
    end
    M.render()
  end))
end

-- Re-render every minute (clock, countdowns) without refetching.
local function start_clock()
  if S.clock then
    return
  end
  S.clock = uv.new_timer()
  S.clock:start((60 - os.time() % 60) * 1000 + 50, 60000, vim.schedule_wrap(M.render))
end

local function cleanup()
  stop_timer("spin")
  stop_timer("clock")
  S.buf, S.ctx, S.plan, S.states, S.regions, S.mapped = nil, nil, nil, {}, {}, {}
  S.gen = S.gen + 1
  -- Deferred (we're inside one of the group's autocmds). Skip if a new dashboard was opened
  -- meanwhile: create_buf() already reset the group and its autocmds belong to the new buffer.
  vim.schedule(function()
    if not valid() then
      pcall(vim.api.nvim_del_augroup_by_name, "ahoy_buf")
    end
  end)
end

local function create_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  S.buf, S.mapped = buf, {}
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, "ahoy://dashboard")
  vim.bo[buf].filetype = "ahoy"

  local grp = vim.api.nvim_create_augroup("ahoy_buf", { clear = true })
  vim.api.nvim_create_autocmd("VimResized", { group = grp, callback = M.render })
  vim.api.nvim_create_autocmd("WinResized", {
    group = grp,
    callback = function()
      for _, w in ipairs(vim.v.event.windows or {}) do
        if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == S.buf then
          return M.render()
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", { group = grp, buffer = buf, callback = M.render })
  vim.api.nvim_create_autocmd("BufWipeout", { group = grp, buffer = buf, callback = cleanup })

  local k = cfg().keys
  for _, key in ipairs({ k.open, k.browser, k.refresh, k.quit }) do
    map(key)
  end
  -- Dial keys only when the section exists (`sections = { dial = false }` leaves counts etc. alone).
  if cfg().sections.dial then
    for _, a in ipairs(cfg().dial) do
      if a.key then
        map(a.key)
      end
    end
  end
end

local function set_win_opts(win)
  local wo = {
    number = false,
    relativenumber = false,
    signcolumn = "no",
    foldcolumn = "0",
    statuscolumn = "",
    colorcolumn = "",
    list = false,
    wrap = false,
    spell = false,
    cursorline = true,
    cursorcolumn = false,
  }
  for o, v in pairs(wo) do
    vim.api.nvim_set_option_value(o, v, { scope = "local", win = win })
  end
end

---Re-detect context and refetch every section.
function M.refresh()
  if not valid() then
    return
  end
  S.gen = S.gen + 1
  local gen = S.gen
  S.ctx, S.plan, S.states = nil, nil, {}
  M.render()
  ensure_spinner()

  local c = cfg()
  context.detect(function(ctx)
    if gen ~= S.gen or not valid() then
      return
    end
    S.ctx = ctx
    S.plan = layout.resolve(c.layouts[ctx.kind], c.sections, ctx, c)
    for _, name in ipairs(S.plan.names) do
      S.states[name] = section.run(c.sections[name], ctx, function()
        if gen == S.gen then
          M.render()
        end
      end)
    end
    M.render()
  end)
end

---Open the dashboard in the current window; refresh if it's already there.
function M.open()
  cfg()
  local win = vim.api.nvim_get_current_win()
  if valid() and vim.api.nvim_win_get_buf(win) == S.buf then
    return M.refresh()
  end
  local cur = vim.api.nvim_get_current_buf()
  if cur ~= S.buf then
    S.prev = cur
  end
  if not valid() then
    create_buf()
  end
  vim.api.nvim_win_set_buf(win, S.buf)
  set_win_opts(win)
  start_clock()
  M.refresh()
end

---Leave the dashboard, returning to the previous buffer.
function M.close()
  if not valid() or vim.api.nvim_win_get_buf(0) ~= S.buf then
    return
  end
  local prev = S.prev
  if prev and prev ~= S.buf and vim.api.nvim_buf_is_valid(prev) and vim.bo[prev].buflisted then
    vim.api.nvim_win_set_buf(0, prev)
  else
    vim.cmd.enew()
  end
end

local function should_show_on_startup()
  if vim.fn.argc() ~= 0 or #vim.api.nvim_list_uis() == 0 then
    return false
  end
  local buf = vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_get_name(buf) ~= "" or vim.bo[buf].modified or vim.bo[buf].buftype ~= "" then
    return false
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  return #lines <= 1 and (lines[1] or "") == ""
end

function M.setup(opts)
  M.config = config.setup(opts)
  render.setup_highlights()

  local grp = vim.api.nvim_create_augroup("ahoy", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = grp, callback = render.setup_highlights })

  if M.config.keymap then
    vim.keymap.set("n", M.config.keymap, M.open, { desc = "Ahoy dashboard" })
  end

  if M.config.show_on_startup then
    local function startup()
      if should_show_on_startup() then
        M.open()
      end
    end
    if vim.v.vim_did_enter == 1 then
      startup()
    else
      vim.api.nvim_create_autocmd("VimEnter", { group = grp, once = true, callback = startup })
    end
  end
end

return M
