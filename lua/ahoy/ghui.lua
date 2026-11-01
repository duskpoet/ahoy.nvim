-- Rendering helpers shared by the GitHub sections.
local util = require("ahoy.util")
local fit = require("ahoy.render").fit

local M = {}

---Collects rows for a section render: `b:add(left_segs, right?, keymaps?)`, then `b:result()`.
---`right` is right-aligned: a string (dim) or a list of segments. It's dropped when too narrow.
function M.builder(width)
  local b = { lines = {}, keymaps = {}, width = width }
  function b:add(left, right, km)
    local segs
    if type(right) == "string" then
      right = right ~= "" and { { right, "AhoyDim" } } or nil
    end
    local rw = right and util.segs_width(right) or 0
    if rw > 0 and self.width - rw - 1 >= 16 then
      segs = fit(left, self.width - rw - 1)
      segs[#segs + 1] = { " " }
      vim.list_extend(segs, right)
    else
      segs = fit(left, self.width, true)
    end
    self.lines[#self.lines + 1] = segs
    self.keymaps[#self.lines] = km
  end
  function b:result()
    return { lines = self.lines, keymaps = self.keymaps }
  end
  return b
end

---CI state glyph + highlight for a PR.
function M.ci_icon(pr)
  local gh = require("ahoy.gh")
  if not pr.ci then
    return "·", "AhoyDim"
  elseif gh.ci_failing(pr) then
    return "✗", "AhoyError"
  elseif gh.ci_pending(pr) then
    return "●", "AhoyWarn"
  end
  return "✓", "AhoyOk"
end

local REVIEW_VERB = {
  APPROVED = { "approved", "AhoyOk" },
  CHANGES_REQUESTED = { "requested changes", "AhoyError" },
  COMMENTED = { "reviewed", "AhoyInfo" },
  DISMISSED = { "dismissed", "AhoyDim" },
}

---`{ verb, hl }` for an activity event.
function M.verb(ev)
  local k = ev.kind
  if k == "review" then
    return REVIEW_VERB[ev.state] or { "reviewed", "AhoyInfo" }
  elseif k == "commit" then
    return { "pushed", "AhoyInfo" }
  elseif k == "force_push" then
    return { "force-pushed", "AhoyWarn" }
  elseif k == "thread" then
    return { "replied", "AhoyWarn" }
  elseif k == "review_requested" then
    return { "requested review from", "AhoyDim" }
  elseif k == "ready" then
    return { "marked ready for review", "AhoyInfo" }
  elseif k == "draft" then
    return { "converted to draft", "AhoyDim" }
  elseif k == "ci_fail" then
    return { "✗", "AhoyError" }
  elseif k == "ci_ok" then
    return { "✓", "AhoyOk" }
  end
  return { "commented", "AhoyInfo" }
end

---Review-state glyph + highlight (per reviewer).
M.review_icon = {
  APPROVED = { "✓", "AhoyOk" },
  CHANGES_REQUESTED = { "✗", "AhoyError" },
  COMMENTED = { "◦", "AhoyInfo" },
  PENDING = { "●", "AhoyWarn" },
  DISMISSED = { "–", "AhoyDim" },
}

---Pad `s` to display width `w`.
function M.pad(s, w)
  return s .. string.rep(" ", math.max(0, w - util.width(s)))
end

---Join `{ text, hl }` summary parts with " · " (skips nils).
function M.summary(parts)
  local segs = {}
  for _, p in ipairs(parts) do
    if p then
      if #segs > 0 then
        segs[#segs + 1] = { " · ", "AhoyDim" }
      end
      segs[#segs + 1] = p
    end
  end
  return segs
end

return M
