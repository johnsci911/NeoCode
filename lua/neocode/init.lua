local M = {}

local REQUIRED_FIELDS = { "name", "launch_cmd", "interrupt", "attach_image", "session_store" }

local DEFAULT_CONFIG = {
  default_adapter    = "opencode",
  keymap_prefix      = "<leader>ai",
  data_dir           = vim.fn.stdpath("data") .. "/neocode",
  telescope_fallback = true,
  winbar             = "  ? help  /session history  i input  <M-n>r rename  <M-n>c stop  <M-n>q close  <C-p> image  H toggle  { } cycle\n",
  adapters           = {},
}

M._config      = {}
M._initialized = false

local function adapter_available(name)
  local cmd = vim.fn.executable(name)
  return cmd == 1
end

local function auto_detect_adapters()
  local adapters = {}
  if adapter_available("opencode") then
    adapters.opencode = require("neocode.adapters.opencode")
  end
  if adapter_available("pi") then
    adapters.pi = require("neocode.adapters.pi")
  end
  return adapters
end

local function validate_adapter(name, adapter)
  for _, field in ipairs(REQUIRED_FIELDS) do
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
  opts = opts or {}
  if not opts.adapters or next(opts.adapters) == nil then
    opts.adapters = auto_detect_adapters()
  end
  M._config = vim.tbl_deep_extend("force", DEFAULT_CONFIG, opts)

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
