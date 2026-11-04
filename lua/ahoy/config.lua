local M = {}

---Built-in sections (modules under `ahoy.sections`).
M.builtin = { "status", "dial", "waiting", "my_prs", "latest", "pr", "threads", "activity", "next_meeting", "calendar" }

M.defaults = {
  show_on_startup = true,
  ---Normal-mode mapping that opens/refreshes the dashboard, e.g. "<leader>a". nil = none.
  keymap = nil,
  ---false disables the idle pool entirely.
  idle = true,
  ---User sections: a list of specs or a map of name -> spec. `name = false` disables a built-in.
  sections = {},
  ---Quick dial actions (the `dial` section; hidden while empty). Each:
  ---  { key = "1", label = "…", desc = "…", when = fn(ctx), input = "Prompt: ",
  ---    run = fn(ctx, input) | cmd = "Ex {input}" | harner = "/skill {input}" | fn(ctx, input) }
  dial = {},
  ---The calendar is the hero everywhere; it never goes empty (setup hint / "no meetings today").
  ---The quick dial comes right after it.
  layouts = {
    main = { header = "status", hero = "calendar", cards = { "dial", "waiting", "my_prs", "latest" } },
    pr = { header = "status", hero = "calendar", cards = { "dial", "pr", "threads", "activity" } },
    global = { hero = "calendar", cards = { "dial", "waiting", "streak" } },
  },
  grid = {
    two_columns = 160, -- window width at which cards go two-up
    compact = 100, -- below this width margins shrink
    max_width = 220, -- content is centered and capped at this width
    card_max_lines = 14,
    hero_max_lines = 18, -- room for the calendar hero: headline, day strip, agenda
  },
  keys = { open = "<CR>", browser = "o", refresh = "r", quit = "q" },
  ---How `o` (and browser-type <CR>) handle URLs: "auto" copies to the clipboard (+) over SSH and
  ---opens otherwise, falling back to copy; "open", "copy", or function(url).
  browser = "auto",
  ---IANA zone for clocks and the calendar ("Europe/Berlin"); nil = system zone. Handy on a remote box.
  timezone = nil,
  calendar = {
    url_file = "~/.config/ahoy/ics_url", -- private ICS URL; keep it chmod 600
    email = nil, -- whose RSVP counts for "declined"; nil = the calendar's name if it's an email
    day_start = 9, -- working-day bounds for the progress bar (hours, display zone)
    day_end = 18,
  },
  github = {
    limit = 30, -- max PRs per search
    mentions_days = 14, -- only mentions in issues/PRs updated this recently
    latest = 12, -- rows in the `latest` card
    max_reviews = 5, -- review requests listed in `waiting`; older ones collapse into one row
    hide_bots = true, -- drop bot authors (CI, linters, Linear…) from `latest`
  },
}

local function valid_section(s)
  return type(s) == "table" and type(s.name) == "string" and type(s.render) == "function"
    and (s.fetch == nil or type(s.fetch) == "function")
end

---nil if dial action `a` is usable, else why not.
local function valid_dial(a)
  if type(a) ~= "table" then
    return "not a table"
  end
  local n = (a.run ~= nil and 1 or 0) + (a.cmd ~= nil and 1 or 0) + (a.harner ~= nil and 1 or 0)
  if n ~= 1 then
    return "needs exactly one of run, cmd, harner"
  elseif a.run ~= nil and type(a.run) ~= "function" then
    return "run must be a function"
  elseif a.cmd ~= nil and type(a.cmd) ~= "string" then
    return "cmd must be a string"
  elseif a.harner ~= nil and type(a.harner) ~= "string" and type(a.harner) ~= "function" then
    return "harner must be a string or function"
  elseif a.key ~= nil and (type(a.key) ~= "string" or a.key == "") then
    return "key must be a non-empty string"
  elseif a.when ~= nil and type(a.when) ~= "function" then
    return "when must be a function"
  end
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
    elseif k == "grid" or k == "keys" or k == "github" or k == "calendar" then
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

  local reserved = {}
  for _, k in pairs(cfg.keys) do
    reserved[k] = true
  end
  local dial, always = {}, {} -- always[key]: an action without `when` already uses it
  for i, a in ipairs(type(cfg.dial) == "table" and cfg.dial or {}) do
    local why = valid_dial(a)
    if why then
      vim.notify(("ahoy: ignoring dial #%d (%s)"):format(i, why), vim.log.levels.WARN)
    else
      if a.key and reserved[a.key] then
        vim.notify(("ahoy: dial key %q clashes with a dashboard key; unbound"):format(a.key), vim.log.levels.WARN)
        a = vim.tbl_extend("force", a, { key = false })
      elseif a.key and always[a.key] then
        -- Shared keys are fine when `when` keeps them apart; after an unconditional one they never fire.
        vim.notify(("ahoy: dial key %q already used by an earlier action; #%d only runs via <CR>"):format(a.key, i), vim.log.levels.WARN)
      end
      if a.key and not a.when then
        always[a.key] = true
      end
      dial[#dial + 1] = a
    end
  end
  cfg.dial = dial

  return cfg
end

return M
