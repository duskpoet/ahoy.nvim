local uv = require("ahoy.util").uv

local M = {}

M.default_timeout = 30000

---Run a section's fetch. Returns a state table that is mutated in place:
---  { status = "loading"|"ok"|"empty"|"error", data?, err?, ms? }
---`done(data)` → ok, `done(nil)` → empty, `done(nil, err)` → error.
---`on_done(state)` is called on the main loop once the fetch settles.
function M.run(spec, ctx, on_done)
  local st = { status = "loading", started = uv.hrtime() }
  local settled = false

  local function done(data, err)
    if settled then
      return
    end
    settled = true
    vim.schedule(function()
      st.ms = (uv.hrtime() - st.started) / 1e6
      if err ~= nil then
        st.status, st.err = "error", tostring(err)
      elseif data == nil then
        st.status = "empty"
      else
        st.status, st.data = "ok", data
      end
      on_done(st)
    end)
  end

  if not spec.fetch then
    done(true)
    return st
  end

  local ok, e = pcall(spec.fetch, ctx, done)
  if not ok then
    done(nil, e)
  end

  local timeout = spec.timeout == nil and M.default_timeout or spec.timeout
  if timeout and not settled then
    vim.defer_fn(function()
      done(nil, ("timed out after %ds"):format(timeout / 1000))
    end, timeout)
  end

  return st
end

return M
