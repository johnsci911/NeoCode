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
    local active_map = {}
    for _, s in ipairs(session._all()) do
      -- Skip empty sessions (no messages sent yet)
      if not s.messages or #s.messages == 0 then goto skip_mem end
      active_map[s.id] = s
      ::skip_mem::
    end

    local entries = {}
    local seen = {}

    -- Add disk sessions (with in-memory overrides for active ones)
    for _, s in ipairs(all) do
      seen[s.id] = true
      local mem = active_map[s.id]
      local is_active = mem ~= nil
      local title = (mem and mem.title) or s.title
      local timestamp = s.created_at and os.date("%m/%d/%Y %H:%M", s.created_at) or ""

      table.insert(entries, {
        id         = s.id,
        adapter    = s.adapter,
        title      = title,
        status     = is_active and "active" or "closed",
        created_at = s.created_at,
        display    = string.format("%s %s  [%s]  %s",
          is_active and "●" or "○", title, s.adapter, timestamp),
      })
    end

    -- Add in-memory sessions not on disk (only if they have messages)
    for id, s in pairs(active_map) do
      if not seen[id] then
        local timestamp = s.created_at and os.date("%m/%d/%Y %H:%M", s.created_at) or ""
        table.insert(entries, {
          id         = s.id,
          adapter    = s.adapter,
          title      = s.title,
          status     = "active",
          created_at = s.created_at,
          display    = string.format("● %s  [%s]  %s", s.title, s.adapter, timestamp),
        })
      end
    end

    table.sort(entries, function(a, b)
      if a.status ~= b.status then return a.status == "active" end
      return (a.created_at or 0) > (b.created_at or 0)
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

      -- d: delete session(s) - supports multi-select with <Tab>
      map("n", "d", function()
        local picker = action_state.get_current_picker(prompt_bufnr)
        local selections = picker:get_multi_selection()

        -- Fall back to single selection if no multi-select
        if #selections == 0 then
          local entry = action_state.get_selected_entry()
          if entry then selections = { entry } end
        end

        local deleted = 0
        local skipped = 0
        for _, entry in ipairs(selections) do
          local sel = entry.value
          if sel.status == "active" then
            skipped = skipped + 1
          else
            session.delete_from_disk(sel.id, config)
            -- Also delete the llama session messages file
            local llama_session = require("neocode.llama_session")
            local history_dir = config.data_dir .. "/llama"
            llama_session.delete(history_dir, sel.id)
            deleted = deleted + 1
          end
        end

        if skipped > 0 then
          vim.notify("neocode: skipped " .. skipped .. " active session(s) — close them first", vim.log.levels.WARN)
        end
        if deleted > 0 then
          vim.notify("neocode: deleted " .. deleted .. " session(s)", vim.log.levels.INFO)
        end
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
