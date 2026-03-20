local M = {}

function M.open(config)
  local session  = require("neocode.session")

  -- Build options: one entry per configured adapter
  local entries = {}

  local adapter_order = {}
  for name, _ in pairs(config.adapters or {}) do
    table.insert(adapter_order, name)
  end
  table.sort(adapter_order)

  for _, name in ipairs(adapter_order) do
    local label = ({
      claude   = "  Claude CLI",
      opencode = "  OpenCode",
      gemini   = "  Gemini CLI",
    })[name] or ("  " .. name)
    table.insert(entries, { type = "adapter", name = name, display = label })
  end

  local ok_tel, pickers = pcall(require, "telescope.pickers")

  if ok_tel then
    local finders      = require("telescope.finders")
    local conf         = require("telescope.config").values
    local actions      = require("telescope.actions")
    local action_state = require("telescope.actions.state")

    pickers.new({
      layout_strategy = "center",
      layout_config   = {
        width  = 40,
        height = #entries + 4,
        preview_cutoff = 1,
      },
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
          actions.close(prompt_bufnr)
          local sel = action_state.get_selected_entry().value
          if sel.type == "adapter" then
            local adapter = config.adapters[sel.name]
            local n = #session._all() + 1
            session.create(adapter, sel.name .. " " .. n, config)
          end
        end)
        return true
      end,
    }):find()
  else
    -- Fallback: vim.ui.select
    local labels = {}
    for _, e in ipairs(entries) do table.insert(labels, e.display) end
    vim.ui.select(labels, { prompt = "NeoCode" }, function(choice)
      if not choice then return end
      for _, e in ipairs(entries) do
        if e.display == choice then
          if e.type == "adapter" then
            local adapter = config.adapters[e.name]
            local n = #session._all() + 1
            session.create(adapter, e.name .. " " .. n, config)
          end
          break
        end
      end
    end)
  end
end

return M
