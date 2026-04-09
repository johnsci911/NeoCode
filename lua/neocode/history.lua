local M = {}

-- Open Telescope picker showing all sessions (active + closed).
-- Actions: <CR> resume/switch, d delete, r rename, n new session
function M.pick(config)
  local session = require("neocode.session")
  local ok_tel, pickers = pcall(require, "telescope.pickers")
  if not ok_tel then
    vim.notify("neocode: telescope.nvim is required for history picker", vim.log.levels.ERROR)
    return
  end

  local finders      = require("telescope.finders")
  local conf         = require("telescope.config").values
  local actions      = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local function refresh_picker(prompt_bufnr)
    actions.close(prompt_bufnr)
    vim.schedule(function() M.pick(config) end)
  end

  local function build_entries()
    local all = session.load_all_from_disk(config)
    local active_ids = {}
    for _, s in ipairs(session._all()) do
      active_ids[s.id] = true
    end
    local entries = {}
    for _, s in ipairs(all) do
      local is_active = active_ids[s.id] or s.status == "active"
      table.insert(entries, {
        id         = s.id,
        adapter    = s.adapter,
        title      = s.title,
        status     = is_active and "active" or "closed",
        created_at = s.created_at,
        display    = (is_active and "● " or "○ ") .. s.title .. "  [" .. s.adapter .. "]",
      })
    end
    table.sort(entries, function(a, b)
      if a.status ~= b.status then return a.status == "active" end
      return a.created_at > b.created_at
    end)
    return entries
  end

  local entries = build_entries()

  pickers.new({}, {
    prompt_title = "NeoCode Sessions  (<CR> resume · d delete · r rename · n new)",
    finder = finders.new_table({
      results = entries,
      entry_maker = function(entry)
        return { value = entry, display = entry.display, ordinal = entry.title }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, map)
      -- <CR>: resume closed session or switch to active buffer
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local entry = action_state.get_selected_entry()
        if not entry then return end
        local sel = entry.value

        if sel.status == "active" then
          local active = session._get(sel.id)
          if active and active.bufnr and vim.api.nvim_buf_is_valid(active.bufnr) then
            vim.api.nvim_set_current_buf(active.bufnr)
          end
        else
          local adapter = config.adapters and config.adapters[sel.adapter]
          if not adapter then
            vim.notify("neocode: adapter '" .. sel.adapter .. "' not found", vim.log.levels.ERROR)
            return
          end

          -- API adapters: resume by loading saved messages
          if adapter.type == "api" then
            session.resume_api(adapter, sel, config)
            return
          end

          -- CLI adapters: resume via adapter's resume_cmd
          if not adapter.resume_cmd then
            vim.notify("neocode: adapter '" .. sel.adapter .. "' does not support resume", vim.log.levels.ERROR)
            return
          end
          local resume_spec = adapter.resume_cmd({ cwd = vim.fn.getcwd() })

          local record = session._new_record(sel.adapter, sel.title)
          record.id         = sel.id
          record.created_at = sel.created_at
          session._add(record)

          vim.cmd("vsplit")
          local win  = vim.api.nvim_get_current_win()
          local argv = vim.list_extend({ resume_spec.cmd }, resume_spec.args or {})
          session._open_terminal(record, argv, win, config)
        end
      end)

      -- d: delete session
      map("n", "d", function()
        local entry = action_state.get_selected_entry()
        if not entry then return end
        local sel = entry.value
        if sel.status == "active" then
          vim.notify("neocode: close the session first before deleting", vim.log.levels.WARN)
          return
        end
        session.delete_from_disk(sel.id, config)
        refresh_picker(prompt_bufnr)
      end)

      -- r: rename session
      map("n", "r", function()
        local entry = action_state.get_selected_entry()
        if not entry then return end
        local sel = entry.value
        actions.close(prompt_bufnr)
        vim.ui.input({ prompt = "Rename session: ", default = sel.title }, function(input)
          if not input or input == "" then return end
          session.rename_on_disk(sel.id, input, config)
          local active = session._get(sel.id)
          if active then active.title = input end
          vim.schedule(function() M.pick(config) end)
        end)
      end)

      -- n: new session
      map("n", "n", function()
        actions.close(prompt_bufnr)
        local adapter = config.adapters and config.adapters[config.default_adapter]
        if adapter then
          session.create(adapter, nil, config)
        end
      end)

      return true
    end,
  }):find()
end

return M
