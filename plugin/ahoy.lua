if vim.g.loaded_ahoy then
  return
end
vim.g.loaded_ahoy = true

vim.api.nvim_create_user_command("Ahoy", function()
  require("ahoy").open()
end, { desc = "Open (or refresh) the ahoy dashboard" })
