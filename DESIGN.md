# ahoy.nvim — design

A context-aware, extensible startup dashboard built around a GitHub + calendar workflow.

## Opening
- Shows on startup (`show_on_startup = true`, configurable) when nvim starts with no file args.
- Hotkey/command (`:Ahoy`) opens it in the current window; if already open → refresh.
- Fullscreen scratch buffer (`buftype=nofile`, `filetype=ahoy`). `q` returns to previous buffer.

## Data loading
- Render layout immediately; each section shows a spinner in its title and fills in when its async fetch completes.
- No disk cache (may add opt-in per section later).
- All external calls via `vim.system()` (async).

## Context
Gathered once per open, passed to every section as `ctx`:
cwd, git root, branch, default branch, PR number (if branch has a PR), time.

Contexts → layouts:
- `pr` — on a feature branch (non-default). If there is no open PR yet, the `pr` hero shows a "no PR yet" state: push/create hints and diffstat vs base.
- `main` — on the default branch (or detached HEAD)
- `global` — not in a git repo

## Sections (extension unit)
Defined by the user in `setup({ sections = {...} })`. No public registry yet (keep the interface clean so one can be added later).

```lua
{
  name   = "my_prs",
  slots  = { "card", "ticker" },          -- supported slot sizes
  when   = function(ctx) return true end, -- optional
  fetch  = function(ctx, done) done(data) end,
  render = function(data, slot, width) return { lines, highlights, keymaps } end,
}
```

## Slots & layout
- `header` — borderless 1–2 lines at top (repo status: path, branch, clean/dirty, ahead/behind, date/time)
- `hero`   — full-width card (next meeting on main; the PR itself on a PR branch). Accepts a fallback list: first section with data wins.
- `card`   — grid cards; ≥160 cols → 2 columns, <100 → single column; reflow on `VimResized`
- `ticker` — one-line strips (e.g. next meeting on a PR branch)
- `idle`   — fills only otherwise-empty slots; never displaces real info

```lua
layouts = {
  main   = { header = "status", hero = { "next_meeting", "idle" }, cards = { "waiting", "my_prs", "calendar", "latest" } },
  pr     = { header = "status", hero = "pr", cards = { "threads", "activity" }, tickers = { "next_meeting" } },
  global = { hero = { "next_meeting", "idle" }, cards = { "waiting", "streak" } },
}
```

- Footer: keymap legend + per-source fetch timings.
- Countdown and day-progress bar tick every minute via a timer (no refetch).
- Nord palette by default; all highlight groups are links (themeable).

## GitHub (via `gh` CLI)
- `gh api graphql` — one query for the main view where possible.
- PR branch view: checks, review state per reviewer, mergeability, diffstat, timeline, unresolved threads, activity.
- **Waiting on me**: review requests · unresolved review comments on my PRs · my approved+mergeable PRs · my PRs with failing CI · @mentions.
- **Streak**: `contributionsCollection` → 4-week heatmap + current/best streak + this-week count.

## Calendar (Google, private ICS feed)
- URL read from `~/.config/ahoy/ics_url` (chmod 600). Never in `setup()`.
- Fetched with `curl`, parsed in Lua.
- Recurrence subset: `FREQ=DAILY/WEEKLY/MONTHLY`, `INTERVAL`, `BYDAY`, `UNTIL`, `COUNT`, `EXDATE`, `RECURRENCE-ID` overrides, `TZID`. Unsupported rules flagged with ⚠.
- Expansion window: today only.
- Shows: next meeting hero with countdown + rest of today; `<CR>` opens Meet link (from DESCRIPTION/LOCATION).
- Header shows "fetched at" (Google feed can lag).

## Idle pool (rotating, context-aware first)
- No meetings left → deep-work message with free time remaining
- Inbox zero → celebration + "last time: N days ago"
- Roast oldest open PR
- Friday after 16:00 → "Don't deploy." figlet
- After 22:00 → "Go to bed."
- Commit streak heatmap
- Oldest TODO in repo (git blame age) with birthday
- Random fortune/dev quote (local file)
- CI weather (☀ / ⛅ / ⛈)
- `idle = false` disables all.

## State
`stdpath("data")/ahoy/state.json` — small facts only (last inbox zero, idle rotation history to avoid repeats).

## Actions (`<CR>` per row type; `o` always opens in browser)
- Review request → `gh pr checkout` + diff against base (`:Git difftool -y origin/<base>...`)
- Unresolved thread → jump to `file:line`
- Failing CI → `gh run view --log-failed` in a split
- Mergeable → open in browser (ahoy never merges or writes to the remote)
- Mention → open in browser
- My PR row (on main) → `gh pr checkout` + reopen ahoy (PR layout)
