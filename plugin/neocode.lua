-- Auto-load shim: users can call setup() themselves to override defaults.
-- If they never call setup(), this ensures the plugin is initialized with defaults.
if vim.g.neocode_loaded then return end
vim.g.neocode_loaded = true

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

