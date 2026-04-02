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

-- Persistence

local function _sessions_path(config)
  return config.data_dir .. "/sessions.json"
end

local function _write_sessions_json(path, list)
  local ok, encoded = pcall(vim.fn.json_encode, list)
  if ok then
    local f = io.open(path, "w")
    if f then
      f:write(encoded)
      f:close()
    else
      vim.notify("neocode: could not write " .. path, vim.log.levels.WARN)
    end
  end
end

function M._persist(config)
  if not config or not config.data_dir then return end
  local durable = {}
  for _, s in pairs(_sessions) do
    local cfg_adapter    = config.adapters and config.adapters[s.adapter]
    local should_persist = not cfg_adapter or cfg_adapter.session_store ~= false
    if should_persist then
      table.insert(durable, {
        id         = s.id,
        adapter    = s.adapter,
        title      = s.title,
        status     = s.status or "active",
        created_at = s.created_at,
      })
    end
  end
  _write_sessions_json(_sessions_path(config), durable)
end

function M.load_all_from_disk(config)
  if not config or not config.data_dir then return {} end
  local f = io.open(_sessions_path(config))
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
  _write_sessions_json(_sessions_path(config), filtered)
end

function M.rename_on_disk(session_id, new_title, config)
  local all = M.load_all_from_disk(config)
  for _, s in ipairs(all) do
    if s.id == session_id then
      s.title = new_title
      break
    end
  end
  _write_sessions_json(_sessions_path(config), all)
end

-- Terminal lifecycle

-- Spawn a terminal job in `win` for `record` using command `argv`.
-- opts.prev_buf: if set, <Esc> in terminal mode cancels and returns to that buf.
function M._open_terminal(record, argv, win, config, opts)
  opts = opts or {}
  local buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_win_set_buf(win, buf)

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
      M._persist(config)
      M._remove(record.id)
    end,
  })

  record.bufnr  = buf
  record.winid  = win
  record.job_id = job_id

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

-- Create and open a new session in a vertical split terminal buffer.
function M.create(adapter, title, config)
  if adapter.type == "api" then
    M.create_api(adapter, title, config)
  else
    M._create_with_title(adapter, title, config)
  end
end

function M._create_with_title(adapter, title, config)
  local record = M._new_record(adapter.name, title)
  M._add(record)
  _current_id = record.id

  vim.cmd("vsplit")
  local win  = vim.api.nvim_get_current_win()
  local spec = adapter.launch_cmd({ cwd = vim.fn.getcwd(), name = record.title })
  local argv = vim.list_extend({ spec.cmd }, spec.args or {})
  M._open_terminal(record, argv, win, config)
end

function M.create_api(adapter, title, config)
  local chat_buffer = require("neocode.chat_buffer")
  local llama_session_mod = require("neocode.llama_session")

  local record = M._new_record(adapter.name, title)
  record.messages = {}
  record.api_adapter = adapter
  record.pending_image_b64 = nil
  M._add(record)
  _current_id = record.id

  local history_dir = config.data_dir .. "/llama"
  local saved = llama_session_mod.load(history_dir, record.id)
  if #saved > 0 then
    record.messages = saved
  end

  local buf = chat_buffer.create(record.messages)
  record.bufnr = buf

  vim.cmd("vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  record.winid = win

  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].conceallevel = 2
  vim.wo[win].winbar = config.winbar or ""
  vim.wo[win].list = false

  M._register_api_keymaps(buf, record, config)
  M._persist(config)
end

function M._register_api_keymaps(buf, record, config)
  local opts = { buffer = buf, silent = true }

  vim.keymap.set("n", "i", function()
    M._open_api_input(record, config)
  end, opts)

  vim.keymap.set("n", "<C-v>", function()
    M._paste_image_api(record, config)
  end, opts)

  -- Cancel/interrupt streaming response
  vim.keymap.set("n", "<C-c>", function()
    if record.job_id then
      vim.fn.jobstop(record.job_id)
      record.job_id = nil
      vim.bo[record.bufnr].modifiable = true
      local lc = vim.api.nvim_buf_line_count(record.bufnr)
      vim.api.nvim_buf_set_lines(record.bufnr, lc, lc, false, { "", "--- [cancelled] ---" })
      vim.bo[record.bufnr].modifiable = false
      vim.notify("neocode: response cancelled", vim.log.levels.INFO)
    end
  end, opts)

  vim.keymap.set("n", "}", function() M.cycle("next", config) end, opts)
  vim.keymap.set("n", "{", function() M.cycle("prev", config) end, opts)
  vim.keymap.set("n", "<S-p>", function() M.pick(config) end, opts)
  vim.keymap.set("n", "?", function()
    require("neocode.hints").toggle()
  end, opts)
  vim.keymap.set("n", "H", function() M.toggle(config) end, opts)
end

function M._open_api_input(record, config)
  local chat_buffer = require("neocode.chat_buffer")
  local llama_session_mod = require("neocode.llama_session")
  local llama = record.api_adapter

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype  = "markdown"
  vim.bo[buf].bufhidden = "wipe"

  local width  = math.floor(vim.o.columns * 0.7)
  local height = math.floor(vim.o.lines * 0.3)
  local row    = math.floor((vim.o.lines - height) / 2)
  local col    = math.floor((vim.o.columns - width) / 2)

  local title = " NeoCode Input — <C-s> send · <C-v> paste image · <Esc> cancel "
  if record.pending_image_b64 then
    title = " NeoCode Input [image attached] — <C-s> send · <Esc> cancel "
  end

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row      = row,
    col      = col,
    width    = width,
    height   = height,
    style    = "minimal",
    border   = "rounded",
    title    = title,
    title_pos = "center",
  })

  vim.wo[win].wrap      = true
  vim.wo[win].linebreak = true
  vim.cmd("startinsert")

  local function send_and_close()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text  = table.concat(lines, "\n")
    if text == "" then
      vim.api.nvim_win_close(win, true)
      return
    end
    vim.api.nvim_win_close(win, true)

    local web_search = require("neocode.web_search")

    local function do_stream()
      local user_msg = llama._build_user_message(text, record.pending_image_b64)
      record.pending_image_b64 = nil
      table.insert(record.messages, user_msg)

      chat_buffer.refresh(record.bufnr, record.messages)

      table.insert(record.messages, { role = "assistant", content = "" })
      vim.bo[record.bufnr].modifiable = true
      local lc = vim.api.nvim_buf_line_count(record.bufnr)
      vim.api.nvim_buf_set_lines(record.bufnr, lc, lc, false, { "", "### Assistant", "", "💭 Thinking..." })
      vim.bo[record.bufnr].modifiable = false
      for _, w in ipairs(vim.fn.win_findbuf(record.bufnr)) do
        local total = vim.api.nvim_buf_line_count(record.bufnr)
        vim.api.nvim_win_set_cursor(w, { total, 0 })
      end

      -- Spinner animation with phase tracking
      local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
      local spinner_idx = 1
      local spinner_active = true
      local spinner_phase = "thinking"
      local phase_start = vim.uv.hrtime()
      local spinner_timer = vim.uv.new_timer()

      spinner_timer:start(80, 80, vim.schedule_wrap(function()
        if not spinner_active then return end
        if not vim.api.nvim_buf_is_valid(record.bufnr) then
          spinner_active = false
          spinner_timer:stop()
          return
        end
        spinner_idx = spinner_idx % #spinner_frames + 1
        local total = vim.api.nvim_buf_line_count(record.bufnr)
        local last = vim.api.nvim_buf_get_lines(record.bufnr, total - 1, total, false)[1] or ""
        if last:match("Thinking") or last:match("Generating") or last:match("Searching") then
          local elapsed = (vim.uv.hrtime() - phase_start) / 1e9
          local label
          if spinner_phase == "searching" then
            label = string.format("%s 🔍 Searching web... %.1fs", spinner_frames[spinner_idx], elapsed)
          elseif spinner_phase == "thinking" then
            label = string.format("%s 💭 Thinking... %.1fs", spinner_frames[spinner_idx], elapsed)
          else
            label = string.format("%s ⚡ Generating... %.1fs", spinner_frames[spinner_idx], elapsed)
          end
          vim.bo[record.bufnr].modifiable = true
          vim.api.nvim_buf_set_lines(record.bufnr, total - 1, total, false, { label })
          vim.bo[record.bufnr].modifiable = false
        else
          spinner_active = false
          spinner_timer:stop()
        end
      end))

      llama._on_phase_change = function(phase)
        if phase == "generating" then
          spinner_phase = "generating"
          phase_start = vim.uv.hrtime()
        end
      end

      record.job_id = llama.stream(record.messages, record.bufnr, function(response_text, stats)
        spinner_active = false
        spinner_timer:stop()
        llama._on_phase_change = nil

        record.messages[#record.messages].content = response_text
        record.job_id = nil

        local history_dir = config.data_dir .. "/llama"
        llama_session_mod.save(history_dir, record.id, record.messages)
      end)
    end

    -- Auto-detect if web search is needed
    if web_search.needs_search(text) then
      -- Show searching indicator
      vim.bo[record.bufnr].modifiable = true
      local lc = vim.api.nvim_buf_line_count(record.bufnr)
      vim.api.nvim_buf_set_lines(record.bufnr, lc, lc, false, { "", "🔍 Searching web..." })
      vim.bo[record.bufnr].modifiable = false

      local query = web_search.extract_query(text)
      web_search.search(query, function(results)
        -- Clear searching indicator
        vim.bo[record.bufnr].modifiable = true
        local total = vim.api.nvim_buf_line_count(record.bufnr)
        for i = total, 1, -1 do
          local line = vim.api.nvim_buf_get_lines(record.bufnr, i - 1, i, false)[1] or ""
          if line:match("Searching web") then
            vim.api.nvim_buf_set_lines(record.bufnr, i - 1, i, false, {})
            break
          end
        end
        vim.bo[record.bufnr].modifiable = false

        if results then
          local ctx = web_search.format_context(query, results)
          table.insert(record.messages, { role = "system", content = ctx })
          -- Show search indicator in chat
          vim.bo[record.bufnr].modifiable = true
          local total = vim.api.nvim_buf_line_count(record.bufnr)
          vim.api.nvim_buf_set_lines(record.bufnr, total, total, false,
            { "🔍 *Web search results injected*", "" })
          vim.bo[record.bufnr].modifiable = false
        end
        do_stream()
      end)
    else
      do_stream()
    end
  end

  local function paste_image()
    local images = require("neocode.images")
    local path, err = images.save_clipboard(config.data_dir .. "/images", record.id)
    if not path then
      vim.notify(err, vim.log.levels.ERROR)
      return
    end
    local f = io.open(path, "rb")
    if not f then
      vim.notify("neocode: failed to read image", vim.log.levels.ERROR)
      return
    end
    local data = f:read("*a")
    f:close()
    record.pending_image_b64 = vim.base64.encode(data)
    images.delete_temp(path)
    -- Update title to show image attached
    vim.api.nvim_win_set_config(win, {
      title = " NeoCode Input [image attached] — <C-s> send · <Esc> cancel ",
      title_pos = "center",
    })
    vim.notify("neocode: image attached", vim.log.levels.INFO)
  end

  local function cancel()
    vim.api.nvim_win_close(win, true)
  end

  vim.keymap.set({ "i", "n" }, "<C-s>",  send_and_close, { buffer = buf, silent = true })
  vim.keymap.set({ "i", "n" }, "<M-CR>", send_and_close, { buffer = buf, silent = true })
  vim.keymap.set({ "i", "n" }, "<C-v>",  paste_image,    { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", cancel, { buffer = buf, silent = true })
end

function M._paste_image_api(record, config)
  local images = require("neocode.images")
  local path, err = images.save_clipboard(config.data_dir .. "/images", record.id)
  if not path then
    vim.notify(err, vim.log.levels.ERROR)
    return
  end

  local f = io.open(path, "rb")
  if not f then
    vim.notify("neocode: failed to read image", vim.log.levels.ERROR)
    return
  end
  local data = f:read("*a")
  f:close()

  local b64 = vim.base64.encode(data)
  record.pending_image_b64 = b64

  images.delete_temp(path)

  vim.notify("neocode: image attached - type your message with 'i'", vim.log.levels.INFO)
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

  local function switch_to(id)
    local s = _sessions[id]
    if s and s.bufnr and vim.api.nvim_buf_is_valid(s.bufnr) then
      _current_id = id
      vim.api.nvim_set_current_buf(s.bufnr)
    end
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

-- Toggle (hide / show)

function M.hide()
  local s = M._current()
  if not s or not s.winid or not vim.api.nvim_win_is_valid(s.winid) then return end
  vim.api.nvim_win_close(s.winid, false)
  s.winid = nil
end

function M.show(config)
  local s = M._current()
  if not s or not s.bufnr or not vim.api.nvim_buf_is_valid(s.bufnr) then return end
  if s.winid and vim.api.nvim_win_is_valid(s.winid) then
    vim.api.nvim_set_current_win(s.winid)
    return
  end
  vim.cmd("vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, s.bufnr)
  s.winid = win
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

-- Buffer-local keymaps

function M._register_buf_keymaps(buf, record, config)
  local opts = { buffer = buf, silent = true }

  -- Cycle sessions (normal mode — press <C-\><C-n> to reach normal mode first)
  vim.keymap.set("n", "}", function() M.cycle("next", config) end, opts)
  vim.keymap.set("n", "{", function() M.cycle("prev", config) end, opts)

  -- Session picker
  vim.keymap.set("n", "<S-p>", function() M.pick(config) end, opts)

  -- Image paste (<leader>p avoids shadowing normal-mode p)
  vim.keymap.set("n", "<leader>p", function()
    local adapter = config.adapters and config.adapters[record.adapter]
    if adapter then
      require("neocode.images").paste(adapter, record, config)
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
    require("neocode.hints").toggle()
  end, opts)

  -- h opens the adapter's native session picker (e.g. claude --resume)
  vim.keymap.set("n", "h", function()
    local adapter = config.adapters and config.adapters[record.adapter]
    if not adapter or not adapter.resume_cmd then
      vim.notify("neocode: adapter does not support resume", vim.log.levels.WARN)
      return
    end
    local spec       = adapter.resume_cmd({ cwd = vim.fn.getcwd() })
    local new_record = M._new_record(record.adapter, "Resume")
    M._add(new_record)
    local win      = vim.api.nvim_get_current_win()
    local prev_buf = vim.api.nvim_get_current_buf()
    local argv     = vim.list_extend({ spec.cmd }, spec.args or {})
    M._open_terminal(new_record, argv, win, config, { prev_buf = prev_buf })
  end, opts)

  -- H hides the NeoCode window
  vim.keymap.set("n", "H", function() M.toggle(config) end, opts)

  -- i opens multi-line input window
  vim.keymap.set("n", "i", function()
    local s = M._current()
    require("neocode.input").open(s, config)
  end, opts)
end

return M
