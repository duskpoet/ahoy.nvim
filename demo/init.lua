-- Minimal config for the demo recording: ahoy + fugitive + nord, and an on-screen key display.
local plugin = vim.env.AHOY_PLUGIN or vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local lazy = vim.fn.fnamemodify(plugin, ":h") -- sibling plugins installed by lazy.nvim
vim.g.mapleader = " "
vim.opt.rtp:prepend(plugin)
vim.opt.rtp:append(lazy .. "/vim-fugitive")
vim.opt.rtp:append(lazy .. "/nord-vim")

vim.o.termguicolors = true
vim.o.number = true
vim.o.laststatus = 2
vim.o.showmode = false
vim.o.shada = ""
vim.o.swapfile = false
pcall(vim.cmd.colorscheme, "nord")

-- Tab labels: file name only (fugitive's object paths are long and leak the sandbox path).
function _G.demo_tabline()
  local s = {}
  for i = 1, vim.fn.tabpagenr("$") do
    local buf = vim.fn.tabpagebuflist(i)[vim.fn.tabpagewinnr(i)]
    local name = vim.fn.bufname(buf)
    name = name:match("^ahoy://") and "ahoy" or vim.fn.fnamemodify(name, ":t")
    s[#s + 1] = (i == vim.fn.tabpagenr() and "%#TabLineSel#" or "%#TabLine#") .. " " .. (name ~= "" and name or "[No Name]") .. " "
  end
  return table.concat(s) .. "%#TabLineFill#"
end
vim.o.tabline = "%!v:lua.demo_tabline()"

require("ahoy").setup({
  keymap = "<leader>a",
  calendar = { email = "sam@example.com" },
})

-- Key display ------------------------------------------------------------------------------
-- Shows the last few normal-mode keys in a float at the bottom right, fading after a pause.
local NAMES = { ["<CR>"] = "⏎", ["<Space>"] = "␣", ["<Esc>"] = "Esc", ["<Tab>"] = "⇥", ["<BS>"] = "⌫" }
local ns = vim.api.nvim_create_namespace("demo_keys")
local keys, win, buf, timer = {}, nil, nil, vim.uv.new_timer()

vim.api.nvim_set_hl(0, "DemoKeys", { fg = "#2E3440", bg = "#EBCB8B", bold = true })

local function hide()
  keys = {}
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  win = nil
end

local function show()
  local text = " " .. table.concat(keys, " ") .. " "
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    buf = vim.api.nvim_create_buf(false, true)
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { end_col = #text, hl_group = "DemoKeys" })
  local w = vim.fn.strdisplaywidth(text)
  local cfg = { relative = "editor", row = vim.o.lines - 4, col = vim.o.columns - w - 3, width = w, height = 1,
    style = "minimal", focusable = false, zindex = 250, noautocmd = true }
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_set_config(win, cfg)
  else
    win = vim.api.nvim_open_win(buf, false, cfg)
  end
  vim.wo[win].winhighlight = "Normal:DemoKeys"
end

vim.on_key(function(_, typed)
  if not typed or typed == "" or vim.fn.mode() ~= "n" then
    return
  end
  local k = vim.fn.keytrans(typed)
  if k:match("^<.*Mouse") or k:match("^<Scroll") then
    return
  end
  keys[#keys + 1] = NAMES[k] or k
  while #keys > 6 do
    table.remove(keys, 1)
  end
  vim.schedule(show)
  timer:stop()
  timer:start(1400, 0, vim.schedule_wrap(hide))
end, ns)
