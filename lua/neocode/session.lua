local M = {}

-- In-memory session table: id → session record
local _sessions = {}
-- Current active session id
local _current_id = nil
-- Counter for unique id generation (avoids same-second timestamp collisions)
local _counter = 0

-- ── Internal helpers (prefixed _ for testing access) ──────────────────

local function generate_uuid()
  return vim.fn.system("uuidgen"):gsub("%s+", ""):lower()
end

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
    session_uuid = generate_uuid(),   -- passed to claude --session-id
    adapter      = adapter_name,
    title        = title or ("Session " .. id),
    status       = "active",          -- "active" | "closed"
    created_at   = os.time(),
    -- runtime fields (not persisted):
    bufnr         = nil,
    winid         = nil,
    job_id        = nil,
    pending_image = nil,
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

-- ── Public API ─────────────────────────────────────────────────────────

-- Create and open a new session in a vertical split terminal buffer.
-- adapter: adapter module table
-- title: optional string; prompts user if nil
function M.create(adapter, title, config)
  if not title then
    vim.ui.input({ prompt = "Session name: " }, function(input)
      if not input or input == "" then
        local n = #M._all() + 1
        input = "Session " .. n
      end
      M._create_with_title(adapter, input, config)
    end)
  else
    M._create_with_title(adapter, title, config)
  end
end

function M._create_with_title(adapter, title, config)
  local record = M._new_record(adapter.name, title)
  M._add(record)
  _current_id = record.id

  -- Open vertical split terminal
  vim.cmd("vsplit")
  local win = vim.api.nvim_get_current_win()
  local spec = adapter.launch_cmd({
    cwd          = vim.fn.getcwd(),
    session_uuid = record.session_uuid,
    name         = record.title,
  })
  local buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_win_set_buf(win, buf)

  local argv = vim.list_extend({ spec.cmd }, spec.args or {})
  local job_id = vim.fn.termopen(argv, {
    on_exit = function()
      if record.pending_image then
        require("neocode.images").delete_temp(record.pending_image)
        record.pending_image = nil
      end
      -- Mark closed but keep in store so history picker can resume it
      record.status = "closed"
      record.bufnr  = nil
      record.winid  = nil
      record.job_id = nil
      M._persist(config)
      -- Remove from in-memory active table
      M._remove(record.id)
    end,
  })

  record.bufnr  = buf
  record.winid  = win
  record.job_id = job_id

  -- Register buffer-local keymaps for this session
  M._register_buf_keymaps(buf, record, config)

  -- Persist durable state
  M._persist(config)

  vim.cmd("startinsert")
end

-- Cycle to next/prev session
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
  _current_id = next_session.id

  -- Switch to the session's buffer in current window
  if next_session.bufnr and vim.api.nvim_buf_is_valid(next_session.bufnr) then
    vim.api.nvim_set_current_buf(next_session.bufnr)
  end
end

-- Open session picker (Telescope or vim.ui.select fallback)
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
          local id = id_map[selection[1]]
          local s  = _sessions[id]
          if s and s.bufnr and vim.api.nvim_buf_is_valid(s.bufnr) then
            _current_id = id
            vim.api.nvim_set_current_buf(s.bufnr)
          end
        end)
        return true
      end,
    }):find()
  else
    vim.ui.select(titles, { prompt = "NeoCode Sessions" }, function(choice)
      if not choice then return end
      local id = id_map[choice]
      local s  = _sessions[id]
      if s and s.bufnr and vim.api.nvim_buf_is_valid(s.bufnr) then
        _current_id = id
        vim.api.nvim_set_current_buf(s.bufnr)
      end
    end)
  end
end

-- ── Persistence ────────────────────────────────────────────────────────

function M._persist(config)
  if not config or not config.data_dir then return end
  local path = config.data_dir .. "/sessions.json"
  local durable = {}
  for _, s in pairs(_sessions) do
    local cfg_adapter  = config.adapters and config.adapters[s.adapter]
    local should_persist = not cfg_adapter or cfg_adapter.session_store ~= false
    if should_persist then
      table.insert(durable, {
        id           = s.id,
        session_uuid = s.session_uuid,
        adapter      = s.adapter,
        title        = s.title,
        status       = s.status or "active",
        created_at   = s.created_at,
      })
    end
  end
  local ok, encoded = pcall(vim.fn.json_encode, durable)
  if ok then
    local f = io.open(path, "w")
    if f then
      f:write(encoded)
      f:close()
    else
      vim.notify("neocode: could not write sessions.json to " .. path, vim.log.levels.WARN)
    end
  end
end

function M.load_all_from_disk(config)
  if not config or not config.data_dir then return {} end
  local path = config.data_dir .. "/sessions.json"
  local f = io.open(path)
  if not f then return {} end
  local ok, data = pcall(vim.fn.json_decode, f:read("*a"))
  f:close()
  if not ok or type(data) ~= "table" then return {} end
  return data
end

function M.delete_from_disk(session_id, config)
  local all = M.load_all_from_disk(config)
  local filtered = {}
  for _, s in ipairs(all) do
    if s.id ~= session_id then
      table.insert(filtered, s)
    end
  end
  local path = config.data_dir .. "/sessions.json"
  local ok, encoded = pcall(vim.fn.json_encode, filtered)
  if ok then
    local f = io.open(path, "w")
    if f then f:write(encoded); f:close() end
  end
end

function M.rename_on_disk(session_id, new_title, config)
  local all = M.load_all_from_disk(config)
  for _, s in ipairs(all) do
    if s.id == session_id then
      s.title = new_title
      break
    end
  end
  local path = config.data_dir .. "/sessions.json"
  local ok, encoded = pcall(vim.fn.json_encode, all)
  if ok then
    local f = io.open(path, "w")
    if f then f:write(encoded); f:close() end
  end
end

-- ── Buffer-local keymaps ───────────────────────────────────────────────

function M._register_buf_keymaps(buf, record, config)
  local opts = { buffer = buf, silent = true }

  -- Cycle sessions (normal mode — press <C-\><C-n> to reach normal mode first)
  vim.keymap.set("n", "}", function() M.cycle("next", config) end, opts)
  vim.keymap.set("n", "{", function() M.cycle("prev", config) end, opts)

  -- Session picker
  vim.keymap.set("n", "<S-p>", function() M.pick(config) end, opts)

  -- Image paste (<leader>p avoids shadowing normal-mode p)
  vim.keymap.set("n", "<leader>p", function()
    local neocode = require("neocode")
    local adapter_name = record.adapter
    local adapter = neocode._config.adapters[adapter_name]
    if adapter then
      require("neocode.images").paste(adapter, record, neocode._config)
    end
  end, opts)

  -- Interrupt AI — both normal and terminal mode
  local function send_interrupt()
    local s = M._current()
    if s and s.job_id then vim.fn.chansend(s.job_id, "\x03") end
  end
  vim.keymap.set("n", "<C-c>", send_interrupt, opts)
  vim.keymap.set("t", "<C-c>", send_interrupt, opts)

  -- ? toggles hint overlay
  vim.keymap.set("n", "?", function()
    require("neocode.hints").toggle(config)
  end, opts)

  -- h opens Claude's native session picker (claude --resume)
  vim.keymap.set("n", "h", function()
    local adapter = config.adapters and config.adapters[record.adapter]
    if not adapter or not adapter.resume_cmd then
      vim.notify("neocode: adapter does not support resume", vim.log.levels.WARN)
      return
    end
    local spec = adapter.resume_cmd({ cwd = vim.fn.getcwd() })
    local new_record = M._new_record(record.adapter, "Resume")
    M._add(new_record)
    -- Replace current window instead of spawning a new split
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_win_set_buf(win, buf)
    local argv = vim.list_extend({ spec.cmd }, spec.args or {})
    local job_id = vim.fn.termopen(argv, {
      on_exit = function()
        new_record.status = "closed"
        new_record.bufnr  = nil
        new_record.winid  = nil
        new_record.job_id = nil
        M._persist(config)
        M._remove(new_record.id)
      end,
    })
    new_record.bufnr  = buf
    new_record.winid  = win
    new_record.job_id = job_id
    M._register_buf_keymaps(buf, new_record, config)
    M._persist(config)
    vim.cmd("startinsert")
  end, opts)

  -- i opens multi-line input window
  vim.keymap.set("n", "i", function()
    local s = M._current()
    require("neocode.input").open(s, config)
  end, opts)
end

return M
