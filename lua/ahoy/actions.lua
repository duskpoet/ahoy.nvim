-- Row actions. Local only: ahoy never merges, pushes, comments or otherwise writes to a remote.
local util = require("ahoy.util")

local M = {}

local function notify(msg, level)
  vim.notify("ahoy: " .. msg, level or vim.log.levels.INFO)
end

local function keys()
  local ok, ahoy = pcall(require, "ahoy")
  return ok and ahoy.config and ahoy.config.keys or require("ahoy.config").defaults.keys
end

---Copy `url` to the system clipboard ("+": reaches the local machine over SSH when the
---clipboard provider is OSC 52). Falls back to writing OSC 52 directly.
function M.copy(url)
  local ok = pcall(vim.fn.setreg, "+", url)
  if not ok then
    ok = pcall(function()
      require("vim.ui.clipboard.osc52").copy("+")({ url })
    end)
  end
  if ok then
    notify("copied " .. url)
  else
    notify("couldn't copy; URL: " .. url, vim.log.levels.WARN)
  end
end

local function remote()
  return (vim.env.SSH_CONNECTION or vim.env.SSH_TTY or "") ~= ""
end

---Open `url` per `config.browser`: "auto" (copy over SSH, else open; copy if opening fails),
---"open", "copy", or a function(url).
function M.browser(url)
  if not url then
    return notify("no URL for this row", vim.log.levels.WARN)
  end
  local ok_cfg, ahoy = pcall(require, "ahoy")
  local mode = ok_cfg and ahoy.config and ahoy.config.browser or "auto"
  if type(mode) == "function" then
    return mode(url)
  end
  if mode == "copy" or (mode == "auto" and remote()) then
    return M.copy(url)
  end
  local ok, res, err = pcall(vim.ui.open, url)
  if ok and not err then
    return
  end
  local msg = tostring(ok and err or res)
  if mode == "auto" then
    notify("can't open browser (" .. msg .. ")", vim.log.levels.WARN)
    return M.copy(url)
  end
  notify("could not open " .. url .. ": " .. msg, vim.log.levels.ERROR)
end

---Row keymaps: `<CR>` runs `open` (defaults to the browser), `o` always opens `url` in the browser.
function M.row(url, open)
  local k = keys()
  return {
    [k.open] = open or function()
      M.browser(url)
    end,
    [k.browser] = function()
      M.browser(url)
    end,
  }
end

---Is `pr` in the repo we're sitting in?
local function here(pr, ctx)
  return ctx and ctx.root and ctx.repo and pr.repo == ctx.repo
end

---`gh pr checkout <n>` in ctx.root, then `after()`. Falls back to the browser for other repos.
function M.checkout(pr, ctx, after)
  if not here(pr, ctx) then
    notify(("%s isn't the current repo; opened in browser"):format(pr.repo or "PR"))
    return M.browser(pr.url)
  end
  if ctx.branch and ctx.branch == pr.head then
    return after and after()
  end
  local dirty = ctx.git and ctx.git.dirty or 0
  if dirty > 0 then
    local c = vim.fn.confirm(
      ("Working tree has %d change(s). Check out #%d anyway?"):format(dirty, pr.number),
      "&Yes\n&No",
      2
    )
    if c ~= 1 then
      return
    end
  end
  notify(("checking out #%d…"):format(pr.number))
  util.run({ "gh", "pr", "checkout", tostring(pr.number) }, { cwd = ctx.root, env = { GH_PROMPT_DISABLED = "1" }, timeout = 60000 }, function(r)
    if r.code ~= 0 then
      local msg = vim.trim(r.stderr or "")
      return notify(("checkout #%d failed: %s"):format(pr.number, msg ~= "" and msg or r.code), vim.log.levels.ERROR)
    end
    vim.cmd("checktime")
    if after then
      after()
    end
  end)
end

---My PR (on main): check it out and reopen ahoy, which now lands in the PR layout.
function M.my_pr(pr, ctx)
  M.checkout(pr, ctx, function()
    require("ahoy").refresh()
  end)
end

---Review request: check out and diff against the base with fugitive.
function M.review(pr, ctx)
  M.checkout(pr, ctx, function()
    if vim.fn.exists(":Git") ~= 2 then
      notify("vim-fugitive not found; checked out #" .. pr.number .. " (no difftool)", vim.log.levels.WARN)
      return require("ahoy").refresh()
    end
    local base = pr.base or (ctx and ctx.default_branch) or "main"
    vim.cmd("Git difftool -y origin/" .. base .. "...")
  end)
end

---Failing CI: `gh run view <id> --log-failed` in a split (falls back to the browser without a run id).
function M.log_failed(check, repo)
  if not check.run_id then
    return M.browser(check.url)
  end
  notify(("fetching failed log for %s…"):format(check.name or check.run_id))
  local cmd = { "gh", "run", "view", tostring(check.run_id), "--log-failed" }
  if repo then
    vim.list_extend(cmd, { "-R", repo })
  end
  util.run(cmd, { env = { GH_PROMPT_DISABLED = "1", NO_COLOR = "1" }, timeout = 60000 }, function(r)
    if r.code ~= 0 then
      local msg = vim.trim(r.stderr or "")
      return notify("log fetch failed: " .. (msg ~= "" and msg or r.code), vim.log.levels.ERROR)
    end
    local out = (r.stdout or ""):gsub("\27%[[%d;]*m", "")
    if vim.trim(out) == "" then
      out = "(no failed-step logs; the run may still be in progress)"
    end
    vim.cmd("botright split")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, buf)
    vim.bo[buf].bufhidden = "wipe"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(out, "\n", { plain = true }))
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = "ahoylog"
    pcall(vim.api.nvim_buf_set_name, buf, ("ahoy://run/%s"):format(check.run_id))
    vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, nowait = true, silent = true })
    vim.cmd("normal! G")
  end)
end

---Jump to a review thread's file:line (relative to ctx.root).
function M.jump(path, line, ctx)
  if not path then
    return
  end
  local full = ctx and ctx.root and (ctx.root .. "/" .. path) or path
  vim.cmd.edit(vim.fn.fnameescape(full))
  if line then
    pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
    vim.cmd("normal! zz")
  end
end

return M
