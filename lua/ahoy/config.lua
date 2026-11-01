local M = {}

---Built-in sections (modules under `ahoy.sections`).
M.builtin = { "status" }

M.defaults = {
  show_on_startup = true,
  ---Normal-mode mapping that opens/refreshes the dashboard, e.g. "<leader>a". nil = none.
  keymap = nil,
  ---false disables the idle pool entirely.
  idle = true,
  ---User sections: a list of specs or a map of name -> spec. `name = false` disables a built-in.
  sections = {},
  layouts = {
    main = { header = "status", hero = { "next_meeting", "idle" }, cards = { "waiting", "my_prs", "calendar", "latest" } },
    pr = { header = "status", hero = "pr", cards = { "threads", "activity" }, tickers = { "next_meeting" } },
    global = { hero = { "next_meeting", "idle" }, cards = { "waiting", "streak" } },
  },
  grid = {
    two_columns = 160, -- window width at which cards go two-up
    compact = 100, -- below this width margins shrink
    max_width = 220, -- content is centered and capped at this width
    card_max_lines = 14,
    hero_max_lines = 10,
  },
  keys = { open = "<CR>", browser = "o", refresh = "r", quit = "q" },
}

local function valid_section(s)
  return type(s) == "table" and type(s.name) == "string" and type(s.render) == "function"
    and (s.fetch == nil or type(s.fetch) == "function")
end

function M.setup(opts)
  opts = opts or {}
  local cfg = vim.deepcopy(M.defaults)

  for k, v in pairs(opts) do
    if k == "layouts" then
      -- Merge per context, but replace each slot wholesale (lists are never merged index-wise).
      for kind, l in pairs(v) do
        cfg.layouts[kind] = l and vim.tbl_extend("force", cfg.layouts[kind] or {}, l) or nil
      end
    elseif k == "grid" or k == "keys" then
      cfg[k] = vim.tbl_extend("force", cfg[k], v)
    elseif k ~= "sections" then
      cfg[k] = v
    end
  end

  local sections = {}
  for _, mod in ipairs(M.builtin) do
    local s = require("ahoy.sections." .. mod)
    sections[s.name] = s
  end
  for k, s in pairs(opts.sections or {}) do
    if s == false and type(k) == "string" then
      sections[k] = nil
    else
      if type(k) == "string" and type(s) == "table" and s.name == nil then
        s.name = k
      end
      if valid_section(s) then
        sections[s.name] = s
      else
        vim.notify(
          ("ahoy: ignoring invalid section %s (needs name and render)"):format(vim.inspect(k)),
          vim.log.levels.WARN
        )
      end
    end
  end
  cfg.sections = sections

  return cfg
end

return M
