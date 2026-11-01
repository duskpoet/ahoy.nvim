# ahoy.nvim — build plan

See DESIGN.md for decisions. Build in thin vertical slices; each slice ends usable and wired into
`~/.config/nvim/lua/plugins.lua` via `{ dir = "~/ahoy.nvim", opts = {...} }`.

## Slice 1 — Core
- [x] Plugin layout: `lua/ahoy/{init,config,context,layout,render,section,util}.lua`, `plugin/ahoy.lua`, `doc/ahoy.txt`
- [x] `setup(opts)` + defaults (`show_on_startup`, `keymap`, `sections`, `layouts`, `idle`)
- [x] Startup: open only when `argc() == 0` and buffer is empty; `:Ahoy` command + hotkey (refresh if already open)
- [x] Scratch buffer (`buftype=nofile`, `filetype=ahoy`), `q` → previous buffer
- [x] Context detection (cwd, git root, branch, default branch, PR number via `gh pr view --json number`) → `pr` | `main` | `global`
- [x] Layout engine: `header` / `hero` (fallback list) / `card` grid (2 cols ≥160, 1 col below; <100 shrinks margins) / `ticker`; reflow on `VimResized`
- [x] Async section runner (`vim.system`), per-section spinner, error state per card
- [x] Footer: keymap legend + per-source timings
- [x] Highlights linked to Nord-friendly defaults
- [x] `status` header section (path, branch, clean/dirty, ahead/behind, date/time)
- [x] Test with a fake `sleep` section (`tests/run.lua`)

## Slice 2 — main view (GitHub)
- [ ] `gh api graphql` wrapper (async, JSON decode, error surfacing)
- [ ] One query: my open PRs (checks, reviewDecision, mergeable, latest activity), review requests, mentions
- [ ] Sections: `waiting` (review req · unresolved threads · mergeable · failing CI · mentions), `my_prs`, `latest`
- [ ] Row actions: `<CR>` per row type, `o` browser (never merge / never write to remote)

## Slice 3 — PR view
- [ ] `pr` hero: CI x/y, per-reviewer state, mergeability, diffstat, timeline
- [ ] `threads` card: unresolved review threads → `<CR>` jumps to file:line
- [ ] `activity` card: comments, pushes, approvals, CI runs
- [ ] Failing CI → `gh run view --log-failed` in a split

## Slice 4 — Calendar (Google ICS)
- [ ] Read URL from `~/.config/ahoy/ics_url`; warn if file perms aren't 600
- [ ] `curl` fetch, line unfolding, VEVENT parse
- [ ] Recurrence subset: DAILY/WEEKLY/MONTHLY, INTERVAL, BYDAY, UNTIL, COUNT, EXDATE, RECURRENCE-ID, TZID; ⚠ on unsupported
- [ ] Expand for today only
- [ ] Fixture tests from a sanitized copy of the real feed
- [ ] `next_meeting` (hero + ticker), `calendar` card; countdown + day progress via 1-min timer; Meet link on `<CR>`; "fetched at"

## Slice 5 — Idle pool & fun
- [ ] State file `stdpath("data")/ahoy/state.json` (last inbox zero, rotation history)
- [ ] Rotation: context-aware first (no meetings, inbox zero, Friday ≥16:00, ≥22:00), then weighted random without repeats
- [ ] Streak heatmap via `contributionsCollection`
- [ ] PR roast, oldest TODO birthday, fortune/quote file, CI weather
- [ ] `idle = false` disables all

## Later / maybe
- Opt-in per-section disk cache
- Public section registry for third-party plugins
