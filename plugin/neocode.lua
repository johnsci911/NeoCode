if vim.g.neocode_loaded then return end
vim.g.neocode_loaded = true

-- Commands are registered in setup(). This file only provides a fallback
-- for users who never call setup() and don't use a plugin manager with config.
vim.api.nvim_create_user_command("Neocode", function()
  local nc = require("neocode")
  if not nc._initialized then nc.setup({}) end
  require("neocode.launcher").open(nc._config)
end, { desc = "Open NeoCode launcher" })

vim.api.nvim_create_user_command("NeocodeToggle", function()
  local nc = require("neocode")
  if not nc._initialized then nc.setup({}) end
  require("neocode.session").toggle(nc._config)
end, { desc = "Toggle NeoCode window" })
