-- Auto-load shim: users can call setup() themselves to override defaults.
-- If they never call setup(), this ensures the plugin is initialized with defaults.
if vim.g.neocode_loaded then return end
vim.g.neocode_loaded = true
vim.schedule(function()
  if not require("neocode")._initialized then
    require("neocode").setup({})
  end
end)
