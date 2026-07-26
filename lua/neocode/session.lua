local M = {}

-- In-memory session table: id → session record
local _sessions = {}
-- Current active session id
local _current_id = nil
-- Counter for unique id generation (avoids same-second timestamp collisions)
local _counter = 0

-- Internal helpers (prefixed _ for testing access)

function M._reset()
  _sessions  = {}
  _current_id = nil
  _counter   = 0
end

function M._new_record(adapter_name, title)
  _counter = _counter + 1
  local id = "neocode_" .. tostring(os.time()) .. "_" .. _counter
  return {
    id           = id,
    adapter      = adapter_name,
    title        = title or ("Session " .. id),
    status       = "active",
    created_at   = os.time(),
    bufnr         = nil,
    winid         = nil,
    job_id        = nil,
  }
end

function M._add(s)
  _sessions[s.id] = s
end

function M._get(id)
  return _sessions[id]
end

function M._remove(id)
  _sessions[id] = nil
  if _current_id == id then _current_id = nil end
end

function M._rename_record(record, new_title)
  if not record or type(new_title) ~= "string" then return false end
  local title = new_title:gsub("^%s+", ""):gsub("%s+$", "")
  if title == "" then return false end
  record.title = title
  return true
end

function M._all()
  local list = {}
  for _, s in pairs(_sessions) do
    table.insert(list, s)
  end
  table.sort(list, function(a, b) return a.created_at < b.created_at end)
  return list
end

function M._current()
  return _current_id and _sessions[_current_id]
end

local function extend_list(dst, src)
  for _, item in ipairs(src or {}) do
    table.insert(dst, item)
  end
end

local function claim_window_for(record, win)
  if not record or not win or not vim.api.nvim_win_is_valid(win) then return end
  for _, session_record in pairs(_sessions) do
    if session_record ~= record and session_record.winid == win then
      session_record.winid = nil
    end
  end
  record.winid = win
end

function M._claim_window_for(record, win)
  claim_window_for(record, win)
end

local function window_shows_record(win, record)
  return record
    and record.bufnr
    and vim.api.nvim_buf_is_valid(record.bufnr)
    and win
    and vim.api.nvim_win_is_valid(win)
    and vim.api.nvim_win_get_buf(win) == record.bufnr
end

local function window_has_transient_session_open(win)
  return win and vim.api.nvim_win_is_valid(win) and vim.w[win].neocode_transient_session_open == true
end

function M._mark_transient_session_open(win)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.w[win].neocode_transient_session_open = true
  end
end

function M._show_session_in_window(record, win)
  if not record or not record.bufnr or not vim.api.nvim_buf_is_valid(record.bufnr) then return false end
  if not win or not vim.api.nvim_win_is_valid(win) then
    win = vim.api.nvim_get_current_win()
  end
  if not win or not vim.api.nvim_win_is_valid(win) then return false end

  vim.api.nvim_win_set_buf(win, record.bufnr)
  _current_id = record.id
  claim_window_for(record, win)
  return true
end

function M._window_for_session_open(record)
  local current = M._current()
  if current and current.winid and window_shows_record(current.winid, current) then
    local win = current.winid
    claim_window_for(record, win)
    return win
  elseif current and current.winid and vim.api.nvim_win_is_valid(current.winid) then
    if window_has_transient_session_open(current.winid) then
      local win = current.winid
      vim.w[win].neocode_transient_session_open = nil
      claim_window_for(record, win)
      return win
    end
    current.winid = nil
  end

  local ok_cur_win, cur_win = pcall(vim.api.nvim_get_current_win)
  if ok_cur_win and cur_win and vim.api.nvim_win_is_valid(cur_win) then
    local cur_buf = vim.api.nvim_win_get_buf(cur_win)
    for _, session_record in pairs(_sessions) do
      if session_record.bufnr == cur_buf then
        claim_window_for(record, cur_win)
        return cur_win
      end
    end
  end

  vim.cmd("vsplit")
  local win = vim.api.nvim_get_current_win()
  if not win or not vim.api.nvim_win_is_valid(win) then
    error("NeoCode could not open a valid session window")
  end
  claim_window_for(record, win)
  return win
end

function M._interrupt_current_cli()
  local s = M._current()
  if s and s.job_id then vim.fn.chansend(s.job_id, "\x03") end
end

function M._send_cli_escape(record)
  local s = record or M._current()
  if s and s.job_id then vim.fn.chansend(s.job_id, "\x1b") end
end

function M._register_session_namespace_keymaps(buf, config, cancel_fn, modes)
  local opts = { buffer = buf, silent = true }
  modes = modes or { "n" }
  vim.keymap.set(modes, "<M-n>q", function() M.close(config) end, opts)
  vim.keymap.set(modes, "<M-n>c", cancel_fn, opts)
  vim.keymap.set(modes, "<M-n>r", function() M.rename_current(config) end, opts)
end

-- Terminal lifecycle

function M._open_terminal(record, argv, win, config, opts)
  opts = opts or {}
  local buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_win_set_buf(win, buf)

  local job_id = vim.fn.termopen(argv, {
    on_exit = function()
      local images = require("neocode.images")
      for _, path in ipairs(record.pending_images or {}) do
        images.delete_temp(path)
      end
      if record.pending_image then
        images.delete_temp(record.pending_image)
        record.pending_image = nil
      end
      record.pending_images = {}
      if record._delete_requested then
        record.status = "deleted"
        record.bufnr  = nil
        record.winid  = nil
        record.job_id = nil
        M.delete_from_disk(record.id, config)
        M._remove(record.id)
        return
      end
      record.status = "closed"
      record.bufnr  = nil
      record.winid  = nil
      record.job_id = nil
      M._persist(config)
      M._remove(record.id)
    end,
  })

  record.bufnr  = buf
  record.winid  = win
  record.job_id = job_id
  _current_id = record.id

  vim.wo[win].winbar = config.winbar or ""
  vim.wo[win].list   = false
  M._register_buf_keymaps(buf, record, config)

  if opts.prev_buf then
    vim.keymap.set("t", "<Esc>", function()
      vim.fn.chansend(record.job_id, "\x03")
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(opts.prev_buf) then
          vim.api.nvim_win_set_buf(win, opts.prev_buf)
          vim.cmd("startinsert")
        end
      end)
    end, { buffer = buf, silent = true })
  end

  M._persist(config)
  vim.cmd("startinsert")
end

-- Public API

function M.create(adapter, title, config)
  local record = M._new_record(adapter.name, title)
  M._add(record)

  local win = M._window_for_session_open(record)
  _current_id = record.id
  local spec = adapter.launch_cmd({ cwd = vim.fn.getcwd(), name = record.title })
  local argv = vim.list_extend({ spec.cmd }, spec.args or {})
  M._open_terminal(record, argv, win, config)
end

function M.resume(adapter, session_data, config)
  local existing = M._get(session_data.id)
  if existing and existing.bufnr and vim.api.nvim_buf_is_valid(existing.bufnr) then
    M._show_session_in_window(existing, vim.api.nvim_get_current_win())
    return
  end

  if existing then M._remove(session_data.id) end

  local record = {
    id           = session_data.id,
    adapter      = adapter.name,
    title        = session_data.title,
    status       = "active",
    created_at   = session_data.created_at,
    bufnr        = nil,
    winid        = nil,
    job_id       = nil,
  }
  M._add(record)

  local win = M._window_for_session_open(record)
  _current_id = record.id

  local spec = adapter.resume_cmd({ cwd = vim.fn.getcwd(), name = record.title })
  local argv = vim.list_extend({ spec.cmd }, spec.args or {})
  M._open_terminal(record, argv, win, config)

  M._persist(config)
  vim.notify("neocode: resumed session '" .. record.title .. "'", vim.log.levels.INFO)
end

function M.delete_from_disk(session_id, config)
  local all = M.load_all_from_disk(config)
  local filtered = {}
  for _, s in ipairs(all) do
    if s.id == session_id then
      -- CLI sessions don't need disk cleanup beyond sessions.json
    else
      table.insert(filtered, s)
    end
  end
  _write_sessions_json(config.data_dir .. "/sessions.json", filtered)
end

function M.delete_active(session_id, config)
  local s = M._get(session_id)
  if not s then return false end

  s._delete_requested = true
  local bufnr = s.bufnr
  local winid = s.winid
  local job_id = s.job_id

  if job_id then
    pcall(vim.fn.jobstop, job_id)
  end

  local images = require("neocode.images")
  for _, path in ipairs(s.pending_images or {}) do
    images.delete_temp(path)
  end
  if s.pending_image then
    images.delete_temp(s.pending_image)
    s.pending_image = nil
  end
  s.pending_images = {}
  s.bufnr = nil
  s.winid = nil
  s.job_id = nil

  M._remove(s.id)
  M.delete_from_disk(s.id, config)

  local remaining = M._all()
  if #remaining > 0 then
    _current_id = remaining[1].id
  end
  if winid and vim.api.nvim_win_is_valid(winid) and #remaining > 0 then
    local next_session = remaining[1]
    if next_session.bufnr and vim.api.nvim_buf_is_valid(next_session.bufnr) then
      M._show_session_in_window(next_session, winid)
    end
  end

  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end

  if winid and vim.api.nvim_win_is_valid(winid) and #remaining == 0 then
    pcall(vim.api.nvim_win_close, winid, true)
  end

  return true
end

function M.rename_on_disk(session_id, new_title, config)
  local all = M.load_all_from_disk(config)
  for _, s in ipairs(all) do
    if s.id == session_id then
      s.title = new_title
      break
    end
  end
  _write_sessions_json(config.data_dir .. "/sessions.json", all)
end

function M.rename_current(config)
  local s = M._current()
  if not s then
    vim.notify("neocode: no active session to rename", vim.log.levels.INFO)
    return
  end
  vim.ui.input({ prompt = "Rename session: ", default = s.title }, function(input)
    if not input or not M._rename_record(s, input) then return end
    M._persist(config)
    vim.notify("neocode: renamed session to '" .. s.title .. "'", vim.log.levels.INFO)
  end)
end

function M.cycle(direction, config)
  local all = M._all()
  if #all <= 1 then return end

  local current_idx = 1
  for i, s in ipairs(all) do
    if s.id == _current_id then current_idx = i end
  end

  local next_idx
  if direction == "next" then
    next_idx = current_idx % #all + 1
  else
    next_idx = (current_idx - 2) % #all + 1
  end

  local next_session = all[next_idx]
  M._show_session_in_window(next_session, vim.api.nvim_get_current_win())
end

function M.pick(config)
  local all = M._all()
  if #all == 0 then
    vim.notify("neocode: no open sessions", vim.log.levels.INFO)
    return
  end

  local titles = {}
  local id_map = {}
  for _, s in ipairs(all) do
    local label = s.title .. " [" .. s.adapter .. "]"
    table.insert(titles, label)
    id_map[label] = s.id
  end

  local use_telescope = config and config.telescope_fallback ~= false
  local ok, telescope = pcall(require, "telescope.pickers")

  local function switch_to(id)
    local s = _sessions[id]
    M._show_session_in_window(s, vim.api.nvim_get_current_win())
  end

  if ok and use_telescope then
    local finders     = require("telescope.finders")
    local conf        = require("telescope.config").values
    local actions     = require("telescope.actions")
    local action_state = require("telescope.actions.state")

    telescope.new({}, {
      prompt_title = "NeoCode Sessions",
      finder = finders.new_table({ results = titles }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_buf, _map)
        actions.select_default:replace(function()
          actions.close(prompt_buf)
          local selection = action_state.get_selected_entry()
          switch_to(id_map[selection[1]])
        end)
        return true
      end,
    }):find()
  else
    vim.ui.select(titles, { prompt = "NeoCode Sessions" }, function(choice)
      if not choice then return end
      switch_to(id_map[choice])
    end)
  end
end

function M.close(config)
  local s = M._current()
  if not s then
    vim.notify("neocode: no active session to close", vim.log.levels.INFO)
    return
  end

  local closed_id = s.id
  local winid = s.winid
  local bufnr = s.bufnr

  if s.job_id then
    pcall(vim.fn.jobstop, s.job_id)
  end

  s.status = "closed"
  s.bufnr = nil
  s.job_id = nil
  M._persist(config)
  M._remove(s.id)

  local images = require("neocode.images")
  for _, path in ipairs(s.pending_images or {}) do
    images.delete_temp(path)
  end
  if s.pending_image then
    images.delete_temp(s.pending_image)
    s.pending_image = nil
  end
  s.pending_images = {}

  local remaining = {}
  for _, session_record in ipairs(M._all()) do
    if session_record.id ~= closed_id then
      table.insert(remaining, session_record)
    end
  end
  if #remaining > 0 then
    local next_session = remaining[1]
    _current_id = next_session.id
    if winid and vim.api.nvim_win_is_valid(winid) then
      if next_session.bufnr and vim.api.nvim_buf_is_valid(next_session.bufnr) then
        vim.api.nvim_win_set_buf(winid, next_session.bufnr)
        claim_window_for(next_session, winid)
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
          pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end
        vim.notify("neocode: switched to '" .. next_session.title .. "'", vim.log.levels.INFO)
        return
      end
    end
  end

  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end

  if winid and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_close(winid, true)
  end

  vim.notify("neocode: session closed", vim.log.levels.INFO)
end

function M.hide()
  local s = M._current()
  if not s or not s.winid or not vim.api.nvim_win_is_valid(s.winid) then return end
  vim.api.nvim_win_close(s.winid, false)
  s.winid = nil
end

function M.show(config)
  local s = M._current()
  if not s or not s.bufnr or not vim.api.nvim_buf_is_valid(s.bufnr) then return end
  if s.winid and window_shows_record(s.winid, s) then
    vim.api.nvim_set_current_win(s.winid)
    return
  elseif s.winid and vim.api.nvim_win_is_valid(s.winid) then
    s.winid = nil
  end
  vim.cmd("vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, s.bufnr)
  claim_window_for(s, win)
  vim.wo[win].winbar = config.winbar or ""
  vim.wo[win].list = false
  vim.cmd("startinsert")
end

function M.toggle(config)
  local s = M._current()
  if s and s.winid and vim.api.nvim_win_is_valid(s.winid) then
    M.hide()
  else
    M.show(config)
  end
end

function M._register_buf_keymaps(buf, record, config)
  local opts = { buffer = buf, silent = true }
  M._register_session_namespace_keymaps(buf, config, M._interrupt_current_cli, { "n", "t" })

  vim.keymap.set("n", "}", function() M.cycle("next", config) end, opts)
  vim.keymap.set("n", "{", function() M.cycle("prev", config) end, opts)

  vim.keymap.set("n", "<S-p>", function() M.pick(config) end, opts)

  vim.keymap.set("n", "<C-p>", function()
    local adapter = config.adapters and config.adapters[record.adapter]
    if adapter then
      require("neocode.images").paste(adapter, record, config)
    end
  end, opts)

  vim.keymap.set("n", "<C-c>", M._interrupt_current_cli, opts)
  vim.keymap.set("t", "<C-c>", function() M._send_cli_escape(record) end, opts)

  vim.keymap.set("n", "?", function()
    require("neocode.hints").toggle()
  end, opts)

  vim.keymap.set("n", "R", function() M.rename_current(config) end, opts)

  vim.keymap.set("n", "H", function() M.toggle(config) end, opts)

  vim.keymap.set("n", "Q", function() M.close(config) end, opts)

  vim.keymap.set("n", "i", function()
    local s = M._current()
    require("neocode.input").open(s, config)
  end, opts)
end

-- Persistence

local function _write_sessions_json(path, list)
  local ok, encoded = pcall(vim.fn.json_encode, list)
  if ok then
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    pcall(vim.fn.setfperm, vim.fn.fnamemodify(path, ":h"), "rwx------")
    local f = io.open(path, "w")
    if f then
      f:write(encoded)
      f:close()
      pcall(vim.fn.setfperm, path, "rw-------")
    else
      vim.notify("neocode: could not write " .. path, vim.log.levels.WARN)
    end
  end
end

function M._persist(config)
  if not config or not config.data_dir then return end

  local existing = M.load_all_from_disk(config)
  local in_memory_ids = {}
  local durable = {}

  for _, s in pairs(_sessions) do
    in_memory_ids[s.id] = true
    table.insert(durable, {
      id         = s.id,
      adapter    = s.adapter,
      title      = s.title,
      status     = s.status or "active",
      created_at = s.created_at,
      cwd        = s.cwd,
    })
  end

  for _, s in ipairs(existing) do
    if not in_memory_ids[s.id] and s.status == "closed" then
      table.insert(durable, s)
    end
  end

  _write_sessions_json(config.data_dir .. "/sessions.json", durable)
end

function M.load_all_from_disk(config)
  if not config or not config.data_dir then return {} end
  local path = config.data_dir .. "/sessions.json"
  local f = io.open(path, "r")
  if not f then return {} end
  local raw = f:read("*a")
  f:close()
  local ok, data = pcall(vim.fn.json_decode, raw)
  if not ok or type(data) ~= "table" then return {} end
  return data
end

return M
