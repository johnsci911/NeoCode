local M = {}

-- Open Telescope picker showing all sessions (active + closed).
-- Actions: <CR> resume/switch, d delete, r rename, n new session
function M.pick(config)
  local session = require("neocode.session")
  local ok_tel, pickers    = pcall(require, "telescope.pickers")
  if not ok_tel then
    vim.notify("neocode: telescope.nvim is required for history picker", vim.log.levels.ERROR)
    return
  end

  local finders     = require("telescope.finders")
  local conf        = require("telescope.config").values
  local actions     = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local function refresh_picker(prompt_bufnr)
    -- Close and reopen to reflect changes
    actions.close(prompt_bufnr)
    vim.schedule(function() M.pick(config) end)
  end

  local function build_entries()
    local all = session.load_all_from_disk(config)
    -- Also include currently active in-memory sessions
    local active_ids = {}
    for _, s in ipairs(session._all()) do
      active_ids[s.id] = true
    end
    local entries = {}
    for _, s in ipairs(all) do
      local is_active = active_ids[s.id] or s.status == "active"
      table.insert(entries, {
        id           = s.id,
        session_uuid = s.session_uuid,
        adapter      = s.adapter,
        title        = s.title,
        status       = is_active and "active" or "closed",
        created_at   = s.created_at,
        display      = (is_active and "● " or "○ ") .. s.title .. "  [" .. s.adapter .. "]",
      })
    end
    -- Sort: active first, then by created_at desc
    table.sort(entries, function(a, b)
      if a.status ~= b.status then
        return a.status == "active"
      end
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
        return {
          value   = entry,
          display = entry.display,
          ordinal = entry.title,
        }
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
          -- Switch to active buffer
          local active = session._get(sel.id)
          if active and active.bufnr and vim.api.nvim_buf_is_valid(active.bufnr) then
            vim.api.nvim_set_current_buf(active.bufnr)
          end
        else
          -- Resume closed session with claude --resume <uuid>
          local adapter = config.adapters and config.adapters[sel.adapter]
          if not adapter or not adapter.resume_cmd then
            vim.notify("neocode: adapter '" .. sel.adapter .. "' does not support resume", vim.log.levels.ERROR)
            return
          end
          local resume_spec = adapter.resume_cmd({
            session_uuid = sel.session_uuid,
            cwd          = vim.fn.getcwd(),
          })
          -- Create new session record reusing existing id/uuid/title
          local record = {
            id           = sel.id,
            session_uuid = sel.session_uuid,
            adapter      = sel.adapter,
            title        = sel.title,
            status       = "active",
            created_at   = sel.created_at,
            bufnr        = nil,
            winid        = nil,
            job_id       = nil,
            pending_image = nil,
          }
          session._add(record)

          vim.cmd("vsplit")
          local win = vim.api.nvim_get_current_win()
          local buf = vim.api.nvim_create_buf(false, false)
          vim.api.nvim_win_set_buf(win, buf)

          local argv = vim.list_extend({ resume_spec.cmd }, resume_spec.args or {})
          local job_id = vim.fn.termopen(argv, {
            on_exit = function()
              if record.pending_image then
                require("neocode.images").delete_temp(record.pending_image)
                record.pending_image = nil
              end
              record.status = "closed"
              record.bufnr  = nil
              record.winid  = nil
              record.job_id = nil
              session._persist(config)
              session._remove(record.id)
            end,
          })

          record.bufnr  = buf
          record.winid  = win
          record.job_id = job_id

          session._register_buf_keymaps(buf, record, config)
          session._persist(config)
          vim.cmd("startinsert")
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
          -- If active, also update in-memory record
          local active = session._get(sel.id)
          if active then active.title = input end
          vim.schedule(function() M.pick(config) end)
        end)
      end)

      -- n: new session
      map("n", "n", function()
        actions.close(prompt_bufnr)
        local adapter_name = config.default_adapter
        local adapter = config.adapters and config.adapters[adapter_name]
        if adapter then
          session.create(adapter, nil, config)
        end
      end)

      return true
    end,
  }):find()
end

return M
