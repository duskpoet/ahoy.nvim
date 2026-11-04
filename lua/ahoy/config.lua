local M = {}

---Built-in sections (modules under `ahoy.sections`).
M.builtin = { "status", "waiting", "my_prs", "latest", "pr", "threads", "activity", "next_meeting", "calendar" }

M.defaults = {
  show_on_startup = true,
  ---Normal-mode mapping that opens/refreshes the dashboard, e.g. "<leader>a". nil = none.
  keymap = nil,
  ---false disables the idle pool entirely.
  idle = true,
  ---User sections: a list of specs or a map of name -> spec. `name = false` disables a built-in.
  sections = {},
  ---The calendar is the hero everywhere; it never goes empty (setup hint / "no meetings today").
  layouts = {
    main = { header = "status", hero = "calendar", cards = { "waiting", "my_prs", "latest" } },
    pr = { header = "status", hero = "calendar", cards = { "pr", "threads", "activity" } },
    global = { hero = "calendar", cards = { "waiting", "streak" } },
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

  return cfg
end

return M
