-- Header: path, branch, clean/dirty, ahead/behind, date/time.
local util = require("ahoy.util")

return {
  name = "status",
  slots = { "header" },
  fetch = function(ctx, done)
    local g = ctx.git or {}
    done({
      root = ctx.root,
      cwd = ctx.cwd,
      branch = ctx.branch,
      detached = g.detached,
      upstream = g.upstream,
      dirty = g.dirty or 0,
      ahead = g.ahead or 0,
      behind = g.behind or 0,
    })
  end,
  render = function(d, _, width)
    local segs = {}
    local function add(t, hl)
      segs[#segs + 1] = { t, hl }
    end
    add(vim.fn.fnamemodify(d.root or d.cwd, ":~"), "AhoyPath")
    if d.root then
      add("  ⎇ " .. (d.branch or (d.detached and "(detached)" or "?")), "AhoyBranch")
      if d.dirty > 0 then
        add("  ● " .. d.dirty .. " changed", "AhoyWarn")
      else
        add("  ✓ clean", "AhoyOk")
      end
      if d.ahead > 0 then
        add("  ↑" .. d.ahead, "AhoyInfo")
      end
      if d.behind > 0 then
        add("  ↓" .. d.behind, "AhoyWarn")
      end
      if d.branch and not d.upstream then
        add("  no upstream", "AhoyDim")
      end
    end
    local right = os.date("%a %d %b  %H:%M")
    local gap = width - util.segs_width(segs) - util.width(right)
    if gap >= 2 then
      add(string.rep(" ", gap))
      add(right, "AhoyDim")
    end
    return { lines = { segs } }
  end,
}
