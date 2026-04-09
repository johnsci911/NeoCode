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

  -- Load existing closed sessions from disk so they don't get wiped
  local existing = M.load_all_from_disk(config)
  local in_memory_ids = {}
  local durable = {}

  -- Add all in-memory sessions
  for _, s in pairs(_sessions) do
    local cfg_adapter    = config.adapters and config.adapters[s.adapter]
    local should_persist = not cfg_adapter or cfg_adapter.session_store ~= false
    if should_persist then
      in_memory_ids[s.id] = true
      table.insert(durable, {
        id         = s.id,
        adapter    = s.adapter,
        title      = s.title,
        status     = s.status or "active",
        created_at = s.created_at,
      })
    end
  end

  -- Preserve closed sessions from disk that aren't in memory
  for _, s in ipairs(existing) do
    if not in_memory_ids[s.id] and s.status == "closed" then
      table.insert(durable, s)
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
  record.cwd = vim.fn.getcwd()
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

  -- Load MCP permissions
  local ok_perms, mcp_perms = pcall(require, "neocode.mcp_permissions")
  if ok_perms then
    mcp_perms.load(config)
  end
end

-- Resume a saved API session by loading its messages from disk.
function M.resume_api(adapter, session_data, config)
  local chat_buffer = require("neocode.chat_buffer")
  local llama_session_mod = require("neocode.llama_session")

  local record = M._new_record(adapter.name, session_data.title)
  record.id = session_data.id
  record.created_at = session_data.created_at
  record.cwd = vim.fn.getcwd()
  record.messages = {}
  record.api_adapter = adapter
  record.pending_image_b64 = nil
  M._add(record)
  _current_id = record.id

  -- Load saved messages
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

  -- Update status and persist
  record.status = "active"
  M._register_api_keymaps(buf, record, config)
  M._persist(config)

  -- Scroll to bottom
  local total = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_win_set_cursor(win, { total, 0 })

  local ok_perms, mcp_perms = pcall(require, "neocode.mcp_permissions")
  if ok_perms then
    mcp_perms.load(config)
  end

  local msg_count = #record.messages
  vim.notify("neocode: resumed session '" .. record.title .. "' (" .. msg_count .. " messages)", vim.log.levels.INFO)
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

  -- h opens session history picker
  vim.keymap.set("n", "h", function()
    require("neocode.history").pick(config)
  end, opts)

  -- Q closes the session
  vim.keymap.set("n", "Q", function() M.close(config) end, opts)
end

-- Compact session: summarize conversation to free context
function M._compact_session(record, config)
  local chat_buffer = require("neocode.chat_buffer")
  local llama_session_mod = require("neocode.llama_session")
  local llama = record.api_adapter

  if #record.messages < 3 then
    vim.notify("neocode: nothing to compact", vim.log.levels.INFO)
    return
  end

  -- Show compacting indicator
  vim.bo[record.bufnr].modifiable = true
  local lc = vim.api.nvim_buf_line_count(record.bufnr)
  vim.api.nvim_buf_set_lines(record.bufnr, lc, lc, false, { "", "🗜️ Compacting conversation..." })
  vim.bo[record.bufnr].modifiable = false

  -- Build summary request: ask the model to summarize
  local conversation_text = {}
  for _, msg in ipairs(record.messages) do
    if msg.role == "user" and type(msg.content) == "string" then
      table.insert(conversation_text, "User: " .. msg.content)
    elseif msg.role == "assistant" and type(msg.content) == "string" and msg.content ~= "" then
      local clean = msg.content:gsub("<think>.-</think>", ""):gsub("^%s+", "")
      if clean ~= "" then
        -- Truncate very long assistant responses
        if #clean > 500 then clean = clean:sub(1, 500) .. "..." end
        table.insert(conversation_text, "Assistant: " .. clean)
      end
    end
  end

  local summary_prompt = {
    { role = "system", content = "Summarize the following conversation in 2-3 concise paragraphs. Capture the key topics discussed, any decisions made, important information shared, and ongoing tasks. This summary will replace the full conversation to save context." },
    { role = "user", content = table.concat(conversation_text, "\n") },
  }

  local cfg = llama.config or llama.defaults
  local url = cfg.base_url .. "/v1/chat/completions"
  local payload = vim.fn.json_encode({
    model = cfg.model,
    messages = summary_prompt,
    stream = false,
    temperature = 0.3,
    max_tokens = 500,
    enable_thinking = false,
  })

  vim.fn.jobstart({
    "curl", "--silent",
    "-X", "POST", url,
    "-H", "Content-Type: application/json",
    "-d", payload,
  }, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      vim.schedule(function()
        local raw = table.concat(data or {}, "")
        if raw == "" then
          vim.notify("neocode: compact failed — no response from model (is it running?)", vim.log.levels.WARN)
          if record.bufnr and vim.api.nvim_buf_is_valid(record.bufnr) then
            chat_buffer.refresh(record.bufnr, record.messages)
          end
          return
        end
        local ok, result = pcall(vim.fn.json_decode, raw)
        local summary = ""
        if ok and result and result.choices and result.choices[1] then
          summary = result.choices[1].message and result.choices[1].message.content or ""
          -- Strip thinking blocks (greedy multiline match)
          summary = summary:gsub("<think>.+</think>", "")
          summary = summary:gsub("<think>.*$", "") -- unclosed think block
          summary = summary:gsub("^%s+", ""):gsub("%s+$", "")
        elseif ok and result and result.error then
          vim.notify("neocode: compact failed — " .. tostring(result.error.message or result.error), vim.log.levels.WARN)
          if record.bufnr and vim.api.nvim_buf_is_valid(record.bufnr) then
            chat_buffer.refresh(record.bufnr, record.messages)
          end
          return
        end

        if summary == "" then
          vim.notify("neocode: compact failed — model returned empty summary (try again)", vim.log.levels.WARN)
          -- Remove compacting indicator
          if record.bufnr and vim.api.nvim_buf_is_valid(record.bufnr) then
            chat_buffer.refresh(record.bufnr, record.messages)
          end
          return
        end

        local old_count = #record.messages

        -- Replace all messages with the summary as a conversation exchange
        record.messages = {
          { role = "user", content = "Summarize our conversation so far." },
          { role = "assistant", content = "Here is a summary of our conversation:\n\n" .. summary },
        }

        -- Refresh display
        chat_buffer.refresh(record.bufnr, record.messages)
        vim.bo[record.bufnr].modifiable = true
        local total = vim.api.nvim_buf_line_count(record.bufnr)
        vim.api.nvim_buf_set_lines(record.bufnr, total, total, false, {
          "",
          "🗜️ Conversation compacted (" .. old_count .. " messages → summary)",
          "",
          "---",
        })
        vim.bo[record.bufnr].modifiable = false

        -- Save compacted history
        local history_dir = config.data_dir .. "/llama"
        llama_session_mod.save(history_dir, record.id, record.messages)

        vim.notify("neocode: conversation compacted", vim.log.levels.INFO)
      end)
    end,
  })
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

    -- Handle /compact command
    if text:match("^%s*/compact") then
      M._compact_session(record, config)
      return
    end

    local web_search = require("neocode.web_search")

    local web_search_active = false

    local function do_stream()
      local user_msg = llama._build_user_message(text, record.pending_image_b64)
      record.pending_image_b64 = nil
      table.insert(record.messages, user_msg)

      -- Auto-title from first user message
      if #record.messages == 1 and type(text) == "string" then
        local title = text:gsub("\n", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        if #title > 50 then title = title:sub(1, 47) .. "..." end
        if title ~= "" then
          record.title = title
          M._persist(config)
        end
      end

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
      local spinner_tool_name = nil
      local phase_start = vim.uv.hrtime()
      local spinner_timer = vim.uv.new_timer()

      spinner_timer:start(80, 80, vim.schedule_wrap(function()
        if not spinner_active then return end
        if not record.bufnr or not vim.api.nvim_buf_is_valid(record.bufnr) then
          spinner_active = false
          spinner_timer:stop()
          return
        end
        spinner_idx = spinner_idx % #spinner_frames + 1
        local total = vim.api.nvim_buf_line_count(record.bufnr)
        local last = vim.api.nvim_buf_get_lines(record.bufnr, total - 1, total, false)[1] or ""
        if last:match("Thinking") or last:match("Generating") or last:match("Searching") or last:match("Tool") then
          local elapsed = (vim.uv.hrtime() - phase_start) / 1e9
          local label
          if spinner_phase == "searching" then
            label = string.format("%s 🔍 Searching web... %.1fs", spinner_frames[spinner_idx], elapsed)
          elseif spinner_phase == "tool" then
            local tool_label = spinner_tool_name or "tool"
            local tool_icon = "🔧"
            local tl = tool_label:lower()
            if tl:match("read") or tl:match("get") or tl:match("list") or tl:match("search") then
              tool_icon = "📖"
            elseif tl:match("write") or tl:match("edit") or tl:match("create") then
              tool_icon = "✏️"
            elseif tl:match("run") or tl:match("exec") or tl:match("command") then
              tool_icon = "⚡"
            end
            label = string.format("%s %s %s... %.1fs", spinner_frames[spinner_idx], tool_icon, tool_label, elapsed)
          elseif spinner_phase == "thinking" then
            -- Show live stats during thinking too
            local live = llama._live_stats
            local extra = ""
            if live and live.token_count and live.token_count > 0 then
              extra = string.format(" · %d tokens", live.token_count)
              if live.tps and live.tps > 0 then
                extra = extra .. string.format(" · %.1f t/s", live.tps)
              end
            end
            label = string.format("%s 💭 Thinking... %.1fs%s", spinner_frames[spinner_idx], elapsed, extra)
          else
            -- Show live t/s and context during generation
            local live = llama._live_stats
            local extra = ""
            if live then
              if live.tps and live.tps > 0 then
                extra = extra .. string.format(" · %.1f t/s", live.tps)
              end
              if live.usage and live.usage.prompt_tokens then
                local ctx_max = live.context_size or 32768
                local used = live.usage.prompt_tokens + (live.token_count or 0)
                extra = extra .. string.format(" · ctx: %d/%d", used, ctx_max)
              end
            end
            label = string.format("%s ⚡ Generating... %.1fs%s", spinner_frames[spinner_idx], elapsed, extra)
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

      -- Check if MCP tools are available (skip when web search is active to save context)
      local ok_mcp, mcp = pcall(require, "neocode.mcp")
      local tools = nil
      if not web_search_active and ok_mcp and mcp.available() then
        tools = mcp.get_all_tools()
      end

      local function on_complete(response_text, stats, _tool_calls)
        spinner_active = false
        spinner_timer:stop()
        llama._on_phase_change = nil

        -- Find the last real assistant message (not empty placeholders)
        for i = #record.messages, 1, -1 do
          if record.messages[i].role == "assistant" then
            record.messages[i].content = response_text
            record.messages[i]._stats = stats
            break
          end
        end

        -- Compress old tool results to save context (keep last round's results intact)
        local tool_msg_count = 0
        for i = #record.messages, 1, -1 do
          if record.messages[i].role == "tool" then
            tool_msg_count = tool_msg_count + 1
            -- Keep last 3 tool results intact, compress older ones
            if tool_msg_count > 3 and #(record.messages[i].content or "") > 200 then
              record.messages[i].content = record.messages[i].content:sub(1, 150) .. "\n...[truncated]"
            end
          end
        end

        record.job_id = nil

        chat_buffer.refresh(record.bufnr, record.messages)

        local history_dir = config.data_dir .. "/llama"
        llama_session_mod.save(history_dir, record.id, record.messages)
      end

      if tools and #tools > 0 then
        -- Use agentic tool-call loop
        local ok_perms, mcp_perms = pcall(require, "neocode.mcp_permissions")

        record.job_id = llama.stream_with_tools(record.messages, record.bufnr, on_complete, {
          tools = tools,
          cwd = record.cwd,
          on_tool_call = function(tool_call, callback)
            local fn = tool_call["function"] or {}
            local server = (fn.name or ""):match("^(.-)__") or "unknown"
            local tool_name = (fn.name or ""):match("__(.+)$") or fn.name or "unknown"

            spinner_phase = "tool"
            spinner_tool_name = tool_name
            phase_start = vim.uv.hrtime()

            local function execute()
              mcp.execute_tool_call(tool_call, function(result, is_error)
                if ok_perms then mcp_perms.consume(server, tool_name) end
                callback(result, is_error)
              end)
            end

            -- Check permissions
            if ok_perms and mcp_perms.is_allowed(server, tool_name) then
              execute()
            elseif ok_perms then
              local ok_args, args = pcall(vim.fn.json_decode, fn.arguments or "{}")
              if not ok_args then args = {} end
              mcp_perms.request(server, tool_name, args, function(allowed)
                if allowed then
                  mcp_perms.save(config)
                  execute()
                else
                  callback("Permission denied by user", true)
                end
              end)
            else
              execute()
            end
          end,
          on_tool_display = function(tool_call, status, result_text)
            -- Update tool call status and store result preview
            for _, msg in ipairs(record.messages) do
              if msg.tool_calls then
                for _, tc in ipairs(msg.tool_calls) do
                  if tc.id == tool_call.id then
                    tc._status = status
                    if result_text then
                      tc._result_preview = result_text
                    end
                  end
                end
              end
            end
            if record.bufnr and vim.api.nvim_buf_is_valid(record.bufnr) then
              chat_buffer.refresh(record.bufnr, record.messages)
            end
          end,
          on_round_start = function(round_num)
            -- Restart spinner for next round
            spinner_active = true
            spinner_phase = "thinking"
            spinner_tool_name = nil
            phase_start = vim.uv.hrtime()

            if record.bufnr and vim.api.nvim_buf_is_valid(record.bufnr) then
              vim.bo[record.bufnr].modifiable = true
              local lc = vim.api.nvim_buf_line_count(record.bufnr)
              vim.api.nvim_buf_set_lines(record.bufnr, lc, lc, false, {
                "", "### Assistant", "", "💭 Thinking..."
              })
              vim.bo[record.bufnr].modifiable = false
              -- Scroll to bottom
              for _, w in ipairs(vim.fn.win_findbuf(record.bufnr)) do
                local total = vim.api.nvim_buf_line_count(record.bufnr)
                vim.api.nvim_win_set_cursor(w, { total, 0 })
              end
            end
          end,
        })
      else
        -- No MCP tools: use normal streaming
        record.job_id = llama.stream(record.messages, record.bufnr, function(response_text, stats)
          on_complete(response_text, stats, nil)
        end)
      end
    end

    -- Auto-detect if web search is needed (skip MCP tools when searching)
    if web_search.needs_search(text) then
      web_search_active = true
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
          -- Remove previous web search system messages to save context
          for i = #record.messages, 1, -1 do
            if record.messages[i].role == "system" and record.messages[i].content:match("web search results") then
              table.remove(record.messages, i)
            end
          end
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

-- Close (end session and clean up)

function M.close(config)
  local s = M._current()
  if not s then
    vim.notify("neocode: no active session to close", vim.log.levels.INFO)
    return
  end

  local closed_id = s.id
  local winid = s.winid
  local bufnr = s.bufnr

  -- Stop any running job (for CLI sessions, on_exit handles persist/remove)
  if s.job_id then
    pcall(vim.fn.jobstop, s.job_id)
  end

  -- For API sessions, save messages and handle cleanup
  if s.api_adapter then
    -- Save messages to disk before closing
    if s.messages and #s.messages > 0 then
      local llama_session_mod = require("neocode.llama_session")
      local history_dir = config.data_dir .. "/llama"
      -- Strip non-serializable runtime fields before saving
      local save_messages = {}
      for _, msg in ipairs(s.messages) do
        local clean = { role = msg.role, content = msg.content }
        if msg.tool_calls then
          local clean_tcs = {}
          for _, tc in ipairs(msg.tool_calls) do
            table.insert(clean_tcs, {
              id = tc.id,
              type = tc.type,
              ["function"] = tc["function"],
            })
          end
          clean.tool_calls = clean_tcs
        end
        if msg.tool_call_id then
          clean.tool_call_id = msg.tool_call_id
        end
        table.insert(save_messages, clean)
      end
      llama_session_mod.save(history_dir, s.id, save_messages)
    end

    s.status = "closed"
    s.bufnr = nil
    s.job_id = nil
    M._persist(config)
    M._remove(s.id)
  end

  -- Clean up pending images
  if s.pending_image then
    require("neocode.images").delete_temp(s.pending_image)
    s.pending_image = nil
  end

  -- Delete the buffer
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end

  -- Switch to another session if one exists, otherwise close the window
  local remaining = M._all()
  if #remaining > 0 then
    local next_session = remaining[1]
    _current_id = next_session.id
    if winid and vim.api.nvim_win_is_valid(winid) then
      if next_session.bufnr and vim.api.nvim_buf_is_valid(next_session.bufnr) then
        vim.api.nvim_win_set_buf(winid, next_session.bufnr)
        next_session.winid = winid
        vim.notify("neocode: switched to '" .. next_session.title .. "'", vim.log.levels.INFO)
        return
      end
    end
  end

  -- No remaining sessions: close the window
  if winid and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_close(winid, true)
  end

  vim.notify("neocode: session closed", vim.log.levels.INFO)
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

  -- Q closes the session
  vim.keymap.set("n", "Q", function() M.close(config) end, opts)

  -- i opens multi-line input window
  vim.keymap.set("n", "i", function()
    local s = M._current()
    require("neocode.input").open(s, config)
  end, opts)
end

return M
