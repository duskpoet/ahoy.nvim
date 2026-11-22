# ahoy.nvim

[![test](https://github.com/duskpoet/ahoy.nvim/actions/workflows/test.yml/badge.svg)](https://github.com/duskpoet/ahoy.nvim/actions/workflows/test.yml)
![Neovim 0.10+](https://img.shields.io/badge/Neovim-0.10%2B-57A143?logo=neovim&logoColor=white)
[![MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

A startup dashboard for Neovim that knows where you are. It shows today's
meetings, and the GitHub work that fits the directory and branch you opened
Neovim in:

- **on a feature branch**: this branch's pull request (checks, reviewers,
  mergeability, diffstat), its unresolved review threads and recent activity;
- **on the default branch**: what is waiting on you (review requests, threads
  on your PRs, failing CI, PRs ready to merge, mentions), your open PRs and
  what others did on them;
- **outside a git repo**: the calendar and what is waiting on you.

```
  ~/code/app  ⎇ feat  ✓ clean                                                      Tue 17 Nov  12:28

  ╭─ Today · Tue 17 Nov ─────────────────────────────────────────────────────────────────────────╮
  │ ● now  Current sync                                                                 20m left │
  │       12:18–12:48                                                              fetched 12:28 │
  │ 08:00 ━━━━━━━━━━━━▆▆▆▆━━━━━━━━━━━━━━━━━━━▆●▆▆───▆▆▆▆──────▆▆▆▆──────────────────────── 18:00 │
  │                                                                                              │
  │   09:28–09:58  Morning thing                                                                 │
  │ ▶ 12:18–12:48  Current sync                                                         20m left │
  │   13:08–13:38  Design review                                                   Meet · in 40m │
  │   13:18–13:28  Skipped                                                              declined │
  │   14:28–14:58  Later chat                                                          in 2h 00m │
  ╰──────────────────────────────────────────────────────────────────────────────────────────────╯

  ╭─ Pull request ───────────────────────────────────────────────────────────────────────────────╮
  │ #42 Make it faster                                                                      open │
  │ checks  ✗ 1 failing · ● 1 running · ✓ 1/3                                                    │
  │ reviews ● alice  ✗ bob  ● @core                                                              │
  │ merge   ● blocked: changes requested                                                         │
  │ diff    +120 −30 · 8 files · 5 commits · main ← feat                                         │
  │ time    opened 3d · last commit 2h · updated 10m · 2 open threads                            │
  │         ✗ unit                                                                         ⏎ log │
  ╰──────────────────────────────────────────────────────────────────────────────────────────────╯

  ╭─ Unresolved threads ────────────────────────╮  ╭─ Activity ──────────────────────────────────╮
  │ ● src/a.lua:2  bob: why?      outdated · 1h │  │ you force-pushed def5678                33m │
  │ ○ src/b.lua:3  bob: renam… 2 comments · 50m │  │ CI ✗ unit                               50m │
  │                                             │  │ bob requested changes  needs work        1h │
  │                                             │  │ you requested review from @core          1h │
  │                                             │  │ you pushed abc1234  speed up             2h │
  ╰─────────────────────────────────────────────╯  ╰─────────────────────────────────────────────╯

  <CR> open   o browser   r refresh   q quit                                                  pr #42
  status 0ms · calendar 0ms · pr 22ms · threads 22ms · activity 23ms
```

(Sample data from the test fixtures, narrowed to fit this page.)

ahoy is read-only towards your remotes: it never merges, pushes or comments.
It shells out to `git`, `gh` and `curl`, and has no Lua dependencies.

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [Tutorial](#tutorial)
- [Keys and row actions](#keys-and-row-actions)
- [Configuration](#configuration)
- [Built-in sections](#built-in-sections)
- [Calendar and privacy](#calendar-and-privacy)
- [Highlight groups](#highlight-groups)
- [Troubleshooting](#troubleshooting)
- [Development](#development)

## Requirements

- Neovim 0.10 or newer
- `git`
- for the GitHub sections: the [GitHub CLI](https://cli.github.com) (`gh`),
  logged in (`gh auth login`)
- for the calendar: `curl`, and a calendar that offers a private iCal (ICS)
  feed, such as Google Calendar
- a font with box-drawing and common symbol glyphs (no Nerd Font needed)
- optional: [vim-fugitive](https://github.com/tpope/vim-fugitive) for the diff
  that opens after checking out a review request;
  [harner.nvim](https://github.com/duskpoet/harner.nvim) for quick dial
  actions that send a prompt to Claude

Each section fails on its own: without `gh` the GitHub cards show an error and
the rest of the dashboard still works.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "duskpoet/ahoy.nvim",
  lazy = false, -- needed for the dashboard to show on startup
  opts = {
    keymap = "<leader>a", -- open / refresh from anywhere
  },
}
```

With any other plugin manager, install `duskpoet/ahoy.nvim` and call:

```lua
require("ahoy").setup({ keymap = "<leader>a" })
```

`:Ahoy` works even without `setup()`; `setup()` is what enables the startup
screen, the mapping and your options.

## Tutorial

This walks from a fresh install to a dashboard with your calendar, your own
shortcuts and a section you wrote yourself. Each step works on its own, so
stop wherever you have enough.

### 1. Open it

Start `nvim` with no file arguments in a git repository. The dashboard takes
over the empty start buffer. Each box shows a spinner in its title while its
data loads, and the footer shows how long each source took.

From anywhere, `:Ahoy` (or your `keymap`) opens the dashboard in the current
window. Run it again while it is open to refresh. Press `q` to go back to the
buffer you came from.

If you would rather open it only on demand, set `show_on_startup = false`.

### 2. Connect GitHub

Make sure `gh` is logged in:

```sh
gh auth status
```

Then press `r` in the dashboard. On the default branch you get three cards:

- **Waiting on me**: review requests, unresolved threads on your PRs, your
  PRs with failing CI, your approved and mergeable PRs, recent mentions;
- **My PRs**: your open PRs with checks passed/total and review state;
- **Latest**: what other people recently did on your PRs.

Move the cursor to a row and press `<CR>` to act on it, or `o` to open it in
the browser. See [Keys and row actions](#keys-and-row-actions) for what `<CR>`
does on each kind of row.

Now check out a feature branch and press `r`. The layout switches to the
branch's pull request, its unresolved threads (`<CR>` jumps to the file and
line) and its activity. If the branch has no PR yet, the card shows the
diffstat against the base branch and the `git push` / `gh pr create` commands;
`<CR>` on those copies the command, ahoy does not run it.

### 3. Connect your calendar

ahoy reads a private ICS feed. For Google Calendar: open *Settings*, pick your
calendar under *Settings for my calendars*, and copy **Secret address in iCal
format**. Anyone with that URL can read your calendar, so it goes in a file
only you can read, never in your Neovim config:

```sh
mkdir -p ~/.config/ahoy
pbpaste > ~/.config/ahoy/ics_url    # or paste it in with an editor
chmod 600 ~/.config/ahoy/ics_url
```

Press `r`. The **Today** box now shows the current or next meeting with a
countdown, a strip of the working day (`━` elapsed, `▆` meetings, `●` now) and
today's agenda. `<CR>` on a meeting with a Meet, Zoom, Teams or Webex link
opens the call.

Two options are worth setting here:

```lua
opts = {
  -- Neovim on a remote machine? Show times in your own zone.
  timezone = "Europe/Berlin",
  -- Working-day bounds of the strip, and whose RSVP marks an event declined.
  calendar = { day_start = 9, day_end = 18, email = "you@example.com" },
}
```

Other calendar providers work as long as they give you an ICS URL.

### 4. Add your own shortcuts (quick dial)

The quick dial is a row of your own actions right under the calendar. It is
hidden until you configure one. An action runs an Ex command, a Lua function,
or sends a prompt to [harner.nvim](https://github.com/duskpoet/harner.nvim):

```lua
opts = {
  dial = {
    { key = "g", label = "Git status", cmd = "botright split | terminal git status" },
    {
      key = "l",
      label = "Log for a path",
      input = "Path: ",            -- asks first; {input} is the answer
      cmd = "botright split | terminal git log --oneline -- {input}",
    },
    {
      key = "t",
      label = "Run tests",
      when = function(ctx) return ctx.kind ~= "global" end, -- only in a repo
      run = function(ctx)
        vim.cmd("botright split | terminal make -C " .. vim.fn.fnameescape(ctx.root) .. " test")
      end,
    },
  },
}
```

Press the action's `key` anywhere in the dashboard, or `<CR>` on its row. The
dashboard closes first so the action lands in your previous buffer; add
`close = false` to keep it open.

### 5. Write a section

A section is a table with a `fetch` that produces data asynchronously and a
`render` that turns the data into lines. This one lists your git stashes:

```lua
opts = {
  sections = {
    stash = {
      title = "Stashes",
      slots = { "card" },
      empty = "no stashes",
      when = function(ctx) return ctx.root ~= nil end, -- only inside a repo
      fetch = function(ctx, done)
        vim.system({ "git", "stash", "list" }, { cwd = ctx.root, text = true }, function(r)
          if r.code ~= 0 then
            return done(nil, vim.trim(r.stderr)) -- shown as an error in the card
          end
          local rows = vim.split(vim.trim(r.stdout), "\n", { trimempty = true })
          done(#rows > 0 and rows or nil)        -- nil: the card shows `empty`
        end)
      end,
      render = function(rows, slot, width)
        local lines, keymaps = {}, {}
        for i, row in ipairs(rows) do
          local ref, msg = row:match("^(stash@{%d+}): (.*)$")
          lines[i] = { { ref .. "  ", "AhoyAccent" }, { msg } }
          keymaps[i] = {
            ["<CR>"] = function()
              vim.cmd("botright split | terminal git stash show -p " .. ref)
            end,
          }
        end
        return { lines = lines, keymaps = keymaps }
      end,
    },
  },
  -- Put it on the dashboard. Setting `cards` replaces the default list.
  layouts = {
    main = { cards = { "dial", "waiting", "my_prs", "latest", "stash" } },
  },
}
```

The same mechanism replaces or removes built-ins: define a section with a
built-in's name to override it, or set `sections = { latest = false }` to drop
it. `:help ahoy-sections` has the full section interface.

## Keys and row actions

In the dashboard:

| Key    | Action                                    |
| ------ | ----------------------------------------- |
| `<CR>` | run the action of the row under the cursor |
| `o`    | open the row in the browser               |
| `r`    | refresh (re-detect context, refetch)      |
| `q`    | return to the previous buffer             |

What `<CR>` does depends on the row:

| Row                       | `<CR>`                                                        |
| ------------------------- | ------------------------------------------------------------- |
| review request            | `gh pr checkout`, then `:Git difftool -y origin/<base>...`    |
| thread on my PR, my PR    | `gh pr checkout`, then refresh into the PR layout             |
| review thread (PR layout) | jump to the file and line                                     |
| failing check             | `gh run view <id> --log-failed` in a split                    |
| ready to merge, mention   | open in the browser                                           |
| meeting with a call link  | open the call                                                 |
| push / create PR hint     | copy the command                                              |

Checkout only happens for PRs in the repository you are in (others open in the
browser) and asks first when the working tree is dirty.

Over SSH, "open in the browser" copies the URL to the `+` register instead, so
it reaches your local clipboard through OSC 52. Set `browser` to `"open"`,
`"copy"` or a `function(url)` to choose.

## Configuration

All options with their defaults:

```lua
require("ahoy").setup({
  show_on_startup = true,
  keymap = nil,                  -- e.g. "<leader>a": open / refresh mapping
  sections = {},                 -- your sections; `name = false` drops a built-in
  dial = {},                     -- quick dial actions
  layouts = {
    main   = { header = "status", hero = "calendar",
               cards = { "dial", "waiting", "my_prs", "latest" } },
    pr     = { header = "status", hero = "calendar",
               cards = { "dial", "pr", "threads", "activity" } },
    global = { hero = "calendar", cards = { "dial", "waiting" } },
  },
  grid = {
    two_columns = 160,           -- window width at which cards go two-up
    compact = 100,               -- below this width margins shrink
    max_width = 220,             -- content is centered and capped at this width
    card_max_lines = 14,
    hero_max_lines = 18,
  },
  keys = { open = "<CR>", browser = "o", refresh = "r", quit = "q" },
  browser = "auto",              -- "auto" | "open" | "copy" | function(url)
  timezone = nil,                -- IANA name, e.g. "Europe/Berlin"; nil = system
  calendar = {
    url_file = "~/.config/ahoy/ics_url",
    email = nil,                 -- whose RSVP counts as "declined"
    day_start = 9,               -- working-day bounds of the day strip (hours)
    day_end = 18,
  },
  github = {
    limit = 30,                  -- max PRs per search
    mentions_days = 14,          -- only mentions updated this recently
    latest = 12,                 -- rows in the `latest` card
    max_reviews = 5,             -- review requests listed before "+N older"
    hide_bots = true,            -- drop bot authors from `latest`
  },
})
```

Layouts are chosen by context: `pr` on a feature branch, `main` on the default
branch or a detached HEAD, `global` outside a git repository. Each has four
slots:

- `header`: one borderless line at the top;
- `hero`: a full-width box. Given a list, the first section that is loading or
  has data wins;
- `tickers`: one-line summaries;
- `cards`: the grid, two-up in wide windows.

Your `layouts` are merged per context, and each slot you set replaces the
default list for that slot.

## Built-in sections

| Section        | Slots              | Shows                                                        |
| -------------- | ------------------ | ------------------------------------------------------------ |
| `status`       | header             | path, branch, clean/dirty, ahead/behind, date and time       |
| `calendar`     | hero, card         | current or next meeting, day strip, today's agenda           |
| `next_meeting` | hero, ticker, card | just the current or next meeting; empty when the day is done |
| `dial`         | card, ticker, hero | your quick dial actions                                      |
| `waiting`      | card, ticker, hero | everything waiting on you across GitHub                      |
| `my_prs`       | card, ticker       | your open PRs: checks, review state, age                     |
| `latest`       | card, ticker       | recent activity by others on your PRs                        |
| `pr`           | hero, card         | this branch's PR, or what to do when there is none yet       |
| `threads`      | card, ticker       | unresolved review threads on this PR (● = waiting on you)    |
| `activity`     | card, ticker       | comments, reviews, pushes, review requests, CI on this PR    |

The GitHub sections share one `gh api graphql` request per refresh.

## Calendar and privacy

- The feed URL is a secret, so it is never accepted in `setup()`. ahoy reads
  it from `calendar.url_file` and warns when that file is readable by anyone
  but you.
- The URL is handed to `curl` on stdin, so it does not appear in `ps`, and it
  is never displayed, logged or included in error messages.
- Nothing is cached on disk. The feed is fetched on each refresh and kept in
  memory only.
- ahoy talks to exactly two places: GitHub through your `gh` login, and the
  calendar URL you configured.

Recurring events are expanded in Lua for today only. Supported: `DAILY`,
`WEEKLY`, `MONTHLY` and `YEARLY` with `INTERVAL`, `BYDAY` (including `2TU` and
`-1FR`), `BYMONTHDAY`, `BYMONTH`, `WKST`, `UNTIL`, `COUNT`, `EXDATE`, `RDATE`,
`RECURRENCE-ID` overrides and `TZID` (from the system zoneinfo). Events using
anything else are marked with ⚠ rather than silently guessed. Google's feed
can lag behind the calendar by a while; the box shows when it was fetched.

## Highlight groups

All groups are default links, so your colorscheme or config can override them:
`AhoyTitle`, `AhoyHeroTitle`, `AhoyBorder`, `AhoyDim`, `AhoyKey`, `AhoyOk`,
`AhoyWarn`, `AhoyError`, `AhoyInfo`, `AhoyAccent`, `AhoyPath`, `AhoyBranch`,
`AhoySpinner`, `AhoyTiming`.

## Troubleshooting

- **The dashboard does not show on startup.** It only opens when Neovim starts
  with no file arguments and an empty buffer, and `setup()` must run during
  startup (`lazy = false` with lazy.nvim). Another start-screen plugin may
  also be claiming the buffer.
- **`gh CLI not found` or `HTTP 401` in the GitHub cards.** Install `gh` and
  run `gh auth login`; check with `gh auth status`.
- **"Calendar not connected".** The file in `calendar.url_file` is missing.
  See [step 3](#3-connect-your-calendar).
- **Meeting times are off.** Neovim is probably running in a different time
  zone than you are (a remote box, a container). Set `timezone`.
- **An event shows ⚠.** It uses a recurrence rule or time zone ahoy does not
  support; its time may be wrong.
- **`o` does nothing over SSH.** The URL was copied to the `+` register. Your
  terminal needs OSC 52 support for it to reach the local clipboard.

## Development

The tests are headless Neovim scripts with stubbed `gh` and `curl`; they need
no network and no GitHub login.

```sh
make test                     # NVIM_BIN=/path/to/nvim to pick a binary
# or one file:
nvim --headless -u NONE -i NONE -c 'luafile tests/calendar.lua'
```

[DESIGN.md](DESIGN.md) records the design decisions, including what is planned
but not built yet (the idle pool and the contribution streak).

## License

[MIT](LICENSE)
