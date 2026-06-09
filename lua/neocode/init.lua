local M = {}

local REQUIRED_CLI_FIELDS = { "name", "launch_cmd", "interrupt", "attach_image", "session_store" }
local REQUIRED_API_FIELDS = { "name", "stream", "stream_with_tools", "_build_user_message", "session_store" }

local DEFAULT_CONFIG = {
  default_adapter    = "claude",
  keymap_prefix      = "<leader>ai",
  data_dir           = vim.fn.stdpath("data") .. "/neocode",
  telescope_fallback = true,
  winbar             = "  ? help  <C-h> resume  i input  R rename  <C-p> image  <C-c> stop  H toggle  { } cycle\n",
  adapters           = {},
  auto_compact       = {
    enabled = false,
    threshold = 0.8,
    preserve_recent_turns = 4,
  },
}

M._config      = {}
M._initialized = false

local function register_builtin_adapters(config)
  config.adapters = config.adapters or {}
  if not config.adapters["local"] then
    local ok, local_adapter = pcall(require, "neocode.adapters.local")
    if ok then
      config.adapters["local"] = local_adapter
    end
  end
end

local function validate_adapter(name, adapter)
  local fields = adapter.type == "api" and REQUIRED_API_FIELDS or REQUIRED_CLI_FIELDS
  for _, field in ipairs(fields) do
    if adapter[field] == nil then
      error(string.format("neocode: adapter '%s' is missing required field '%s'", name, field))
    end
  end
end

function M._register_global_keymaps()
  local prefix = M._config.keymap_prefix
  vim.keymap.set("n", prefix .. "c", function()
    require("neocode.launcher").open(M._config)
  end, { desc = "NeoCode: launcher" })

  vim.keymap.set("n", prefix .. "t", function()
    require("neocode.session").toggle(M._config)
  end, { desc = "NeoCode: toggle window" })
end

function M.setup(opts)
  M._config = vim.tbl_deep_extend("force", DEFAULT_CONFIG, opts or {})
  register_builtin_adapters(M._config)

  for name, adapter in pairs(M._config.adapters) do
    validate_adapter(name, adapter)
  end

  vim.fn.mkdir(M._config.data_dir, "p")
  local images_dir = M._config.data_dir .. "/images"
  vim.fn.mkdir(images_dir, "p")

  -- Clean up stale image folders from crashed sessions
  local live_ids = {}
  local f = io.open(M._config.data_dir .. "/sessions.json")
  if f then
    local ok, data = pcall(vim.fn.json_decode, f:read("*a"))
    f:close()
    if ok and type(data) == "table" then
      for _, s in ipairs(data) do
        if s.id then table.insert(live_ids, s.id) end
      end
    end
  end
  require("neocode.images").cleanup_stale(images_dir, live_ids)

  M._register_global_keymaps()
  M._initialized = true
end

return M
