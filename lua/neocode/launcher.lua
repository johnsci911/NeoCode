local M = {}

local LABEL_MAP = {
  claude = "  Claude CLI",
  opencode = "  OpenCode",
  gemini = "  Gemini CLI",
  llama = "  Llama (Continue)",
  ["local"] = "  NeoCode Local",
}

local function ensure_builtin_adapters(config)
  config.adapters = config.adapters or {}
  if not config.adapters["local"] then
    local ok, local_adapter = pcall(require, "neocode.adapters.local")
    if ok then
      config.adapters["local"] = local_adapter
    end
  end
end

function M._entries(config)
  config = config or {}
  ensure_builtin_adapters(config)

  local adapter_order = {}
  for name in pairs(config.adapters or {}) do
    table.insert(adapter_order, name)
  end
  table.sort(adapter_order)

  local entries = {}
  for _, name in ipairs(adapter_order) do
    local display = LABEL_MAP[name] or ("  " .. name)
    table.insert(entries, { name = name, display = display })
  end
  return entries
end

function M.open(config)
  local session = require("neocode.session")

  local entries = M._entries(config)

  local function on_selected(e)
    local adapter = config.adapters[e.name]
    local n = #session._all() + 1
    session.create(adapter, e.name .. " " .. n, config)
  end

  local ok_tel, pickers = pcall(require, "telescope.pickers")

  if ok_tel then
    local finders      = require("telescope.finders")
    local conf         = require("telescope.config").values
    local actions      = require("telescope.actions")
    local action_state = require("telescope.actions.state")

    pickers.new({
      layout_strategy = "center",
      layout_config   = { width = 40, height = #entries + 4, preview_cutoff = 1 },
    }, {
      prompt_title = "NeoCode",
      finder = finders.new_table({
        results = entries,
        entry_maker = function(e)
          return { value = e, display = e.display, ordinal = e.display }
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, _)
        actions.select_default:replace(function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if entry then
            on_selected(entry.value)
          end
        end)
        return true
      end,
    }):find()
  else
    local labels = {}
    local by_label = {}
    for _, e in ipairs(entries) do
      table.insert(labels, e.display)
      by_label[e.display] = e
    end
    vim.ui.select(labels, { prompt = "NeoCode" }, function(choice)
      if choice then on_selected(by_label[choice]) end
    end)
  end
end

return M
