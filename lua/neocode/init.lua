local M = {}
local session = require("neocode.session")

local REQUIRED_ADAPTER_FIELDS = { "name", "launch_cmd", "interrupt", "attach_image", "session_store" }

local DEFAULT_CONFIG = {
  default_adapter    = "claude",
  keymap_prefix      = "<leader>ai",
  data_dir           = vim.fn.stdpath("data") .. "/neocode",
  telescope_fallback = true,
  winbar             = "  ? help  h resume  i input  <leader>p image  <C-c> stop  { } cycle\n",
  adapters           = {},
}

M._config      = {}
M._initialized = false

local function validate_adapter(name, adapter)
  for _, field in ipairs(REQUIRED_ADAPTER_FIELDS) do
    if adapter[field] == nil then
      error(string.format("neocode: adapter '%s' is missing required field '%s'", name, field))
    end
  end
end

function M._register_global_keymaps()
  local prefix       = M._config.keymap_prefix
  local adapter_name = M._config.default_adapter
  local adapter      = M._config.adapters[adapter_name]

  -- <leader>aiC — startup launcher
  vim.keymap.set("n", prefix .. "C", function()
    require("neocode.launcher").open(M._config)
  end, { desc = "NeoCode: launcher" })
end

function M.setup(opts)
  M._config = vim.tbl_deep_extend("force", DEFAULT_CONFIG, opts or {})

  -- Validate all adapters
  for name, adapter in pairs(M._config.adapters) do
    validate_adapter(name, adapter)
  end

  -- Ensure data_dir exists
  vim.fn.mkdir(M._config.data_dir, "p")
  vim.fn.mkdir(M._config.data_dir .. "/images", "p")

  -- Clean up stale image folders from crashed sessions
  local sessions_path = M._config.data_dir .. "/sessions.json"
  local live_ids = {}
  local f = io.open(sessions_path)
  if f then
    local ok, data = pcall(vim.fn.json_decode, f:read("*a"))
    f:close()
    if ok and type(data) == "table" then
      for _, s in ipairs(data) do
        if s.id then table.insert(live_ids, s.id) end
      end
    end
  end
  require("neocode.images").cleanup_stale(M._config.data_dir, live_ids)

  M._register_global_keymaps()
  M._initialized = true
end

return M
