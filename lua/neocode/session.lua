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

function M._needs_project_tools(text)
  if type(text) ~= "string" then return false end

  local normalized = text:lower():gsub("^%s+", "")
  if normalized == "" then return false end

  if normalized == "@chat" or normalized:match("^@chat[%s:]") then
    return false
  end

  if normalized == "@project" or normalized:match("^@project[%s:]")
    or normalized == "@code" or normalized:match("^@code[%s:]")
    or normalized == "@file" or normalized:match("^@file[%s:]")
    or normalized == "@files" or normalized:match("^@files[%s:]")
    or normalized == "/project" or normalized:match("^/project[%s:]")
    or normalized == "/code" or normalized:match("^/code[%s:]")
    or normalized == "/file" or normalized:match("^/file[%s:]")
    or normalized == "/files" or normalized:match("^/files[%s:]")
    or normalized == "/readfile" or normalized:match("^/readfile[%s:]") then
    return true
  end

  if normalized:match("%f[%w]readme%f[%W]") then
    return true
  end

  if normalized:match("%f[%w]this%s+project%f[%W]")
    or normalized:match("%f[%w]this%s+repo%s*%f[%W]")
    or normalized:match("%f[%w]this%s+repository%f[%W]")
    or normalized:match("%f[%w]this%s+codebase%f[%W]") then
    return true
  end

  if normalized:match("[%w_%-/]+%.[%a][%w_%-]*") then
    return true
  end

  local has_action = normalized:match("%f[%w]read%f[%W]")
    or normalized:match("%f[%w]open%f[%W]")
    or normalized:match("%f[%w]show%f[%W]")
    or normalized:match("%f[%w]inspect%f[%W]")
    or normalized:match("%f[%w]check%f[%W]")
    or normalized:match("%f[%w]review%f[%W]")
    or normalized:match("%f[%w]analy[sz]e%f[%W]")
    or normalized:match("%f[%w]explain%f[%W]")
    or normalized:match("%f[%w]fix%f[%W]")
    or normalized:match("%f[%w]debug%f[%W]")
    or normalized:match("%f[%w]search%f[%W]")
    or normalized:match("%f[%w]find%f[%W]")
    or normalized:match("look%s+at")
    or normalized:match("%f[%w]scan%f[%W]")

  if not has_action then return false end

  return normalized:match("%f[%w]files?%f[%W]") ~= nil
    or normalized:match("%f[%w]directory%f[%W]") ~= nil
    or normalized:match("%f[%w]folder%f[%W]") ~= nil
    or normalized:match("%f[%w]codebase%f[%W]") ~= nil
    or normalized:match("%f[%w]repo%s*%f[%W]") ~= nil
    or normalized:match("%f[%w]repository%f[%W]") ~= nil
    or normalized:match("%f[%w]project%f[%W]") ~= nil
    or normalized:match("%f[%w]app%f[%W]") ~= nil
    or normalized:match("%f[%w]application%f[%W]") ~= nil
    or normalized:match("%f[%w]code%f[%W]") ~= nil
    or normalized:match("%f[%w]laravel%f[%W]") ~= nil
    or normalized:match("%f[%w]routes?%f[%W]") ~= nil
    or normalized:match("%f[%w]controllers?%f[%W]") ~= nil
    or normalized:match("%f[%w]models?%f[%W]") ~= nil
    or normalized:match("%f[%w]migrations?%f[%W]") ~= nil
    or normalized:match("%f[%w]config%f[%W]") ~= nil
    or normalized:match("%f[%w]composer%f[%W]") ~= nil
    or normalized:match("%f[%w]artisan%f[%W]") ~= nil
    or normalized:match("%f[%w]blade%f[%W]") ~= nil
    or normalized:match("%f[%w]php%f[%W]") ~= nil
    or normalized:match("%f[%w]class%f[%W]") ~= nil
    or normalized:match("%f[%w]function%f[%W]") ~= nil
end

local function extend_list(dst, src)
  for _, item in ipairs(src or {}) do
    table.insert(dst, item)
  end
end

function M._build_project_tools(text, cwd)
  local ok_web, web_search = pcall(require, "neocode.web_search")
  local wants_project_tools = M._needs_project_tools(text)
  local wants_web_tool = ok_web and web_search.needs_search(text)
  if not (wants_project_tools or wants_web_tool) then return nil end

  local tools = {}
  local ok_local, local_tools = pcall(require, "neocode.local_tools")
  if ok_local and wants_project_tools then
    extend_list(tools, local_tools.get_tools(cwd))
  end

  if ok_web and wants_web_tool then
    table.insert(tools, web_search.get_tool())
  end

  if #tools == 0 then return nil end
  return tools
end

function M._tool_permission_key(tool_call)
  local fn = tool_call and (tool_call["function"] or tool_call) or {}
  local name = fn.name or "unknown"
  local args = {}
  local ok, parsed = pcall(vim.fn.json_decode, fn.arguments or "{}")
  if ok and type(parsed) == "table" then args = parsed end
  if name == "neocode__run_shell_command" then
    return name .. ":" .. tostring(args.command or "")
  end
  return name
end

function M._save_api_state(config, record)
  if not record or not record.id then return false end
  local store = M._store_for_record(config, record)
  return store.save_state(record.id, {
    tool_permissions = record.tool_permissions or {},
  })
end

function M._load_api_state(config, record)
  if not record or not record.id then return {} end
  local store = M._store_for_record(config, record)
  local state = store.load_state(record.id)
  if type(state) ~= "table" then return {} end
  return state
end

function M._request_tool_permission(record, tool_call, callback, config)
  record.tool_permissions = record.tool_permissions or {}
  local key = M._tool_permission_key(tool_call)
  if record.tool_permissions[key] == true then
    callback(true)
    return
  end

  local fn = tool_call and (tool_call["function"] or tool_call) or {}
  local ok_args, args = pcall(vim.fn.json_decode, fn.arguments or "{}")
  if not ok_args or type(args) ~= "table" then args = {} end
  local command = args.command or fn.name or "tool"

  vim.ui.select({
    "Allow once",
    "Allow and don't ask again",
    "No",
    "Continue prompting",
  }, {
    prompt = "NeoCode wants to run: " .. tostring(command),
  }, function(choice)
    if choice == "Allow and don't ask again" then
      record.tool_permissions[key] = true
      if config then
        M._save_api_state(config, record)
      end
      callback(true)
    elseif choice == "Allow once" then
      callback(true)
    else
      callback(false)
    end
  end)
end

function M._build_memory_context(config, cwd)
  local ok, memory = pcall(require, "neocode.memory")
  if not ok then return nil end
  local store = memory.new({ data_dir = config and config.data_dir, cwd = cwd })
  return store.context_message()
end

function M._build_skills_context(config)
  local selected = config and config.selected_skills or nil
  if type(selected) ~= "table" or #selected == 0 then return nil end
  local ok, skills = pcall(require, "neocode.skills")
  if not ok then return nil end
  local store = skills.new({ data_dir = config and config.data_dir })
  return store.context_message(selected)
end

function M._handle_local_command(text, record, config)
  local thinking_command = text:match("^%s*/thinking%s*(.-)%s*$")
  if thinking_command then
    local thinking_mode = thinking_command ~= "" and thinking_command or nil
    local adapter = record and record.api_adapter
    if adapter and type(adapter.set_thinking) == "function" then
      local ok, message = adapter.set_thinking(thinking_mode)
      vim.notify("neocode: " .. tostring(message or (ok and "thinking mode updated" or "Thinking mode not available")), ok and vim.log.levels.INFO or vim.log.levels.WARN)
    else
      vim.notify("neocode: Thinking mode not available", vim.log.levels.WARN)
    end
    return true
  end

  local memory_text = text:match("^%s*/memory%s+save%s+(.+)%s*$")
  if memory_text then
    local ok, memory = pcall(require, "neocode.memory")
    if ok then
      local store = memory.new({ data_dir = config and config.data_dir, cwd = record and record.cwd })
      store.save({ text = memory_text })
      vim.notify("neocode: saved project memory", vim.log.levels.INFO)
    end
    return true
  end

  local skill_name, skill_content = text:match("^%s*/skill%s+save%s+(%S+)%s+(.+)%s*$")
  if skill_name and skill_content then
    local ok, skills = pcall(require, "neocode.skills")
    if ok then
      skills.new({ data_dir = config and config.data_dir }).save(skill_name, skill_content)
      vim.notify("neocode: saved skill '" .. skill_name .. "'", vim.log.levels.INFO)
    end
    return true
  end

  local selected = text:match("^%s*/skill%s+select%s+(.+)%s*$")
  if selected then
    config.selected_skills = {}
    for name in selected:gmatch("[^,%s]+") do
      table.insert(config.selected_skills, name)
    end
    vim.notify("neocode: selected " .. tostring(#config.selected_skills) .. " skill(s)", vim.log.levels.INFO)
    return true
  end

  return false
end

function M._api_input_text_from_lines(lines)
  lines = vim.deepcopy(lines or {})
  if lines[1] == "Me:" then table.remove(lines, 1) end
  local send_hints = {
    ["Press <C-s> or <M-CR> to send"] = true,
    ["Press <C-s>, <C-CR>, or <M-CR> to send"] = true,
  }
  for i = #lines, 1, -1 do
    if send_hints[lines[i]] then table.remove(lines, i) end
  end
  local text = table.concat(lines, "\n")
  return text:gsub("^\n+", ""):gsub("%s+$", "")
end

function M._api_input_lines_from_text(text)
  local lines = { "Me:" }
  for _, line in ipairs(vim.split(text or "", "\n", { plain = true })) do
    table.insert(lines, line)
  end
  return lines
end

function M._api_inline_draft_text_from_lines(lines)
  local start = nil
  for i = #(lines or {}), 1, -1 do
    if lines[i] == "Me:" then
      start = i
      break
    end
  end
  if not start then return "" end
  local draft = {}
  for i = start, #(lines or {}) do
    table.insert(draft, lines[i])
  end
  return M._api_input_text_from_lines(draft)
end

function M._refresh_api_chat(record, opts)
  local chat_buffer = require("neocode.chat_buffer")
  opts = opts or {}
  if not record or not record.bufnr or not vim.api.nvim_buf_is_valid(record.bufnr) then return end
  chat_buffer.refresh(record.bufnr, record.messages or {}, { draft = opts.draft == true })
  vim.bo[record.bufnr].modifiable = opts.editable == true
  if opts.editable then
    local total = vim.api.nvim_buf_line_count(record.bufnr)
    local target = math.max(1, total - 1)
    pcall(vim.api.nvim_win_set_cursor, record.winid or 0, { target, 0 })
  end
end

local function strip_path_token(path)
  return (path or "")
    :gsub("^[`'\"]+", "")
    :gsub("[`'\"]+$", "")
    :gsub("[,%?%!%:%;%)%]}]+$", "")
end

function M._extract_direct_read_path(text, cwd)
  if type(text) ~= "string" then return nil end

  local normalized = text:lower()
  local asks_to_read = normalized:match("%f[%w]read%f[%W]")
    or normalized:match("%f[%w]open%f[%W]")
    or normalized:match("%f[%w]show%f[%W]")
    or normalized:match("%f[%w]summari[sz]e%f[%W]")
    or normalized:match("%f[%w]explain%f[%W]")
    or normalized:match("%f[%w]inspect%f[%W]")
    or normalized:match("^%s*/readfile[%s:]")

  if not asks_to_read then return nil end

  if normalized:match("%f[%w]readme%f[%W]") and cwd and cwd ~= "" then
    return cwd .. "/README.md"
  end

  for raw_path in text:gmatch("[%w_~/%.-]+%.[%w_%-]+") do
    local path = strip_path_token(raw_path)
    if path ~= "" then
      if path:match("^~/") then
        return vim.fn.expand(path)
      end
      if path:match("^/") then
        return path
      end
      if cwd and cwd ~= "" then
        return cwd .. "/" .. path
      end
    end
  end

  return nil
end

function M._direct_read_fast_path(text, cwd)
  local path = M._extract_direct_read_path(text, cwd)
  if not path then return nil end

  local normalized = text:lower():gsub("^%s+", "")
  normalized = normalized:gsub("^@project[%s:]+", "")
  normalized = normalized:gsub("^@file[%s:]+", "")
  normalized = normalized:gsub("^@files[%s:]+", "")
  normalized = normalized:gsub("^/project[%s:]+", "")
  normalized = normalized:gsub("^/file[%s:]+", "")
  normalized = normalized:gsub("^/files[%s:]+", "")
  normalized = normalized:gsub("^/readfile[%s:]+", "")

  local asks_broad_scope = normalized:match("%f[%w]codebase%f[%W]")
    or normalized:match("%f[%w]project%f[%W]")
    or normalized:match("%f[%w]repo%s*%f[%W]")
    or normalized:match("%f[%w]repository%f[%W]")
    or normalized:match("%f[%w]directory%f[%W]")
    or normalized:match("%f[%w]folder%f[%W]")
    or normalized:match("%f[%w]files%f[%W]")

  if asks_broad_scope then return nil end
  return path
end

function M._build_direct_file_context_message(path, content)
  local max_len = 12000
  local body = content or ""
  if #body > max_len then
    body = body:sub(1, max_len) .. string.format("\n\n[truncated: showing first %d chars of %d]", max_len, #content)
  end

  return {
    role = "system",
    _is_direct_file_context = true,
    content = table.concat({
      "The user asked to read this exact file. Use this content as authoritative context.",
      "Do not inspect other files unless the user explicitly asks.",
      "",
      "File: " .. path,
      "```",
      body,
      "```",
    }, "\n"),
  }
end

local function read_direct_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

local function has_user_message(messages)
  for _, msg in ipairs(messages or {}) do
    if msg.role == "user" then return true end
  end
  return false
end

function M._auto_title_from_first_user_message(record, text, config, is_first_user_message)
  if not is_first_user_message or not record or type(text) ~= "string" then return false end
  local title = text:gsub("\n", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if #title > 50 then title = title:sub(1, 47) .. "..." end
  if title == "" then return false end
  record.title = title
  M._persist(config)
  if record.api_adapter and record.messages and #record.messages > 0 then
    M._save_api_messages(config, record, record.messages)
  end
  return true
end

local function positive_number(value)
  return type(value) == "number" and value > 0
end

local COMPACT_SUMMARY_SECTIONS = {
  "Summary",
  "User Preferences",
  "Decisions",
  "Files / Code Context",
  "Completed",
  "Open Tasks",
  "Important Exact Details",
}

local COMPACT_SUMMARY_INSTRUCTIONS = table.concat({
  "Summarize the following conversation as durable project memory for a future AI turn.",
  "Return only markdown with these exact level-2 headings, in this order:",
  "## Summary",
  "## User Preferences",
  "## Decisions",
  "## Files / Code Context",
  "## Completed",
  "## Open Tasks",
  "## Important Exact Details",
  "Use concise bullets under each heading. Preserve exact file paths, branch names, commands, model names, user constraints, and unresolved tasks.",
  "If a section has no known information, write '- Not captured.' Do not invent details.",
}, "\n")

function M._ensure_structured_compact_summary(summary)
  local text = tostring(summary or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return "" end

  local known_sections = {}
  for _, heading in ipairs(COMPACT_SUMMARY_SECTIONS) do
    known_sections[heading] = true
  end

  local buckets = {}
  local preamble = {}
  for _, heading in ipairs(COMPACT_SUMMARY_SECTIONS) do
    buckets[heading] = {}
  end

  local current_heading = nil
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local heading = line:match("^##%s+(.+)$")
    if heading then
      heading = heading:gsub("%s+$", "")
    end
    if heading and known_sections[heading] then
      current_heading = heading
    elseif current_heading then
      table.insert(buckets[current_heading], line)
    else
      table.insert(preamble, line)
    end
  end

  local preamble_text = table.concat(preamble, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
  if preamble_text ~= "" then
    table.insert(buckets.Summary, 1, preamble_text)
  end

  local parts = {}
  for _, heading in ipairs(COMPACT_SUMMARY_SECTIONS) do
    local content = table.concat(buckets[heading], "\n"):gsub("^%s+", ""):gsub("%s+$", "")
    if content == "" then content = "- Not captured." end
    table.insert(parts, "## " .. heading .. "\n" .. content)
  end

  return table.concat(parts, "\n\n")
end

function M._auto_compact_context_size(config, record, stats)
  stats = stats or {}
  if positive_number(stats.context_size) then return stats.context_size end

  local adapter = record and record.api_adapter
  local adapter_cfg = adapter and (adapter.config or adapter.defaults)
  if adapter_cfg then
    if positive_number(adapter_cfg.context_size) then return adapter_cfg.context_size end
    if positive_number(adapter_cfg.context_length) then return adapter_cfg.context_length end
  end

  local auto_cfg = config and config.auto_compact
  if auto_cfg then
    if positive_number(auto_cfg.context_size) then return auto_cfg.context_size end
    if positive_number(auto_cfg.context_length) then return auto_cfg.context_length end
  end

  return nil
end

function M._auto_compact_used_tokens(stats)
  stats = stats or {}
  local prompt_tokens = stats.prompt_tokens
  if not positive_number(prompt_tokens) and type(stats.usage) == "table" then
    prompt_tokens = stats.usage.prompt_tokens
  end
  if not positive_number(prompt_tokens) then return nil end

  local completion_tokens = stats.completion_tokens
  if not positive_number(completion_tokens) and type(stats.usage) == "table" then
    completion_tokens = stats.usage.completion_tokens
  end

  return prompt_tokens + (positive_number(completion_tokens) and completion_tokens or 0)
end

function M._should_auto_compact(config, record, stats)
  local auto_cfg = config and config.auto_compact
  if not auto_cfg or auto_cfg.enabled ~= true then return false end
  if record and (record._auto_compact_running or record._auto_compact_pending) then return false end

  local context_size = M._auto_compact_context_size(config, record, stats)
  local used_tokens = M._auto_compact_used_tokens(stats)
  if not context_size or not used_tokens then return false end

  local threshold = positive_number(auto_cfg.threshold) and auto_cfg.threshold or 0.8
  if threshold > 1 then threshold = threshold / context_size end
  if threshold <= 0 then threshold = 0.8 end

  return used_tokens >= math.floor(context_size * threshold)
end

function M._mark_auto_compact_if_needed(config, record, stats)
  if not M._should_auto_compact(config, record, stats) then return false end
  if not M._compact_endpoint_config(record) then return false end

  record._auto_compact_pending = true
  record._auto_compact_last_usage = {
    prompt_tokens = (stats and (stats.prompt_tokens or (stats.usage and stats.usage.prompt_tokens))) or nil,
    completion_tokens = (stats and (stats.completion_tokens or (stats.usage and stats.usage.completion_tokens))) or nil,
    used_tokens = M._auto_compact_used_tokens(stats),
    context_size = M._auto_compact_context_size(config, record, stats),
  }
  return true
end

function M._compact_endpoint_config(record)
  local adapter = record and record.api_adapter
  local cfg = adapter and (adapter.config or adapter.defaults)
  if not cfg or type(cfg.base_url) ~= "string" or cfg.base_url == "" then return nil end
  if type(cfg.model) ~= "string" or cfg.model == "" then return nil end
  return cfg
end

function M._compact_chat_url(record)
  local adapter = record and record.api_adapter
  if adapter and adapter.provider and adapter.provider.chat_completions_url then
    return adapter.provider:chat_completions_url()
  end
  local cfg = M._compact_endpoint_config(record)
  if not cfg then return nil end
  local base = cfg.base_url:gsub("/+$", ""):gsub("/v1$", "")
  return base .. "/v1/chat/completions"
end

function M._auto_compact_recent_messages(messages, preserve_recent_turns)
  if not positive_number(preserve_recent_turns) then return {} end

  local kept = {}
  local user_turns = 0
  for i = #(messages or {}), 1, -1 do
    local msg = messages[i]
    if msg.role == "user" then
      user_turns = user_turns + 1
    end
    if msg.role == "user" or msg.role == "assistant" or msg.role == "tool" then
      table.insert(kept, 1, vim.deepcopy(msg))
    end
    if user_turns >= preserve_recent_turns then break end
  end

  return kept
end

function M._auto_compact_messages_to_summarize(messages, preserve_recent_turns)
  local recent = M._auto_compact_recent_messages(messages, preserve_recent_turns)
  local limit = #(messages or {}) - #recent
  local older = {}
  for i = 1, math.max(limit, 0) do
    table.insert(older, messages[i])
  end
  return older
end

-- Persistence

local function _sessions_path(config)
  return config.data_dir .. "/sessions.json"
end

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

local function _read_json_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local raw = f:read("*a")
  f:close()
  local ok, data = pcall(vim.fn.json_decode, raw)
  if ok and type(data) == "table" then return data end
  return nil
end

local function _should_keep_session(config, record)
  if not record or not record.id or not record.adapter then return false end
  local adapters = config.adapters or {}
  local adapter = adapters[record.adapter]
  return not adapter or adapter.session_store ~= false
end

local function _load_layered_session_meta(config)
  local projects_dir = config.data_dir .. "/projects"
  local pattern = projects_dir .. "/*/sessions/*/meta.json"
  local paths = vim.fn.glob(pattern, false, true)
  local sessions = {}
  for _, path in ipairs(paths or {}) do
    local meta = _read_json_file(path)
    if _should_keep_session(config, meta) then
      meta.status = meta.status or "closed"
      table.insert(sessions, meta)
    end
  end
  return sessions
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
        cwd        = s.cwd,
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
  local data = _read_json_file(_sessions_path(config)) or {}
  local by_id = {}
  local order = {}

  local function add_or_replace(record)
    if not _should_keep_session(config, record) then return end
    if not by_id[record.id] then
      table.insert(order, record.id)
    end
    by_id[record.id] = record
  end

  for _, s in ipairs(data) do
    add_or_replace(s)
  end

  for _, s in ipairs(_load_layered_session_meta(config)) do
    add_or_replace(s)
  end

  local sessions = {}
  for _, id in ipairs(order) do
    table.insert(sessions, by_id[id])
  end
  return sessions
end

function M._store_for_record(config, record)
  local session_store = require("neocode.session_store")
  return session_store.new({
    data_dir = config and config.data_dir,
    cwd = (record and record.cwd) or require("neocode.context").find_project_root(),
  })
end

local function normalize_escaped_markdown_fences(content)
  if type(content) ~= "string" or content == "" then return content end
  local lines = {}
  for line in (content .. "\n"):gmatch("([^\n]*)\n") do
    local normalized = line:gsub("^(%s*)\\```", "%1```")
    table.insert(lines, normalized)
  end
  return table.concat(lines, "\n")
end

local function clean_reasoning_artifacts(content)
  if type(content) ~= "string" or content == "" then return content end
  local cleaned = content:gsub("\r\n", "\n")
  local had_reserved = cleaned:find("<|channel>thought", 1, true)
    or cleaned:find("<|channel|>thought", 1, true)
    or cleaned:find("<channel|>", 1, true)
    or cleaned:find("<|start_header_id|>", 1, true)

  cleaned = cleaned:gsub("<[Tt][Hh][Ii][Nn][Kk]>.-</[Tt][Hh][Ii][Nn][Kk]>", "")
  cleaned = cleaned:gsub("<[Tt][Hh][Ii][Nn][Kk]>.*$", "")
  cleaned = cleaned:gsub("<analysis>.-</analysis>", "")
  cleaned = cleaned:gsub("<analysis>.*$", "")
  cleaned = cleaned:gsub("<reasoning>.-</reasoning>", "")
  cleaned = cleaned:gsub("<reasoning>.*$", "")
  cleaned = cleaned:gsub("<｜begin▁of▁sentence｜>", "")
  cleaned = cleaned:gsub("<|start_header_id|>assistant<|end_header_id|>", "")
  cleaned = cleaned:gsub("<|eot_id|>", "")
  cleaned = cleaned:gsub("<|channel|>", "")
  cleaned = cleaned:gsub("<|channel>", "")
  cleaned = cleaned:gsub("<channel|>", "")
  cleaned = cleaned:gsub("^%s+", ""):gsub("%s+$", "")

  if had_reserved then
    for _, pattern in ipairs({ "It%s+", "Here%s+", "To%s+", "The%s+", "This%s+", "For%s+", "If%s+", "You%s+", "I%s+" }) do
      local start_at = cleaned:find(pattern)
      if start_at then return normalize_escaped_markdown_fences(cleaned:sub(start_at):gsub("^%s+", ""):gsub("%s+$", "")) end
    end
  end

  return normalize_escaped_markdown_fences(cleaned)
end

function M._strip_image_payloads_from_messages(messages)
  local stripped_any = false
  for _, msg in ipairs(messages or {}) do
    if type(msg.content) == "table" then
      local kept = {}
      local removed_image = false
      for _, part in ipairs(msg.content) do
        if type(part) == "table" and part.type == "image_url" then
          removed_image = true
        else
          table.insert(kept, part)
        end
      end
      if removed_image then
        stripped_any = true
        if #kept == 1 and type(kept[1]) == "table" and kept[1].type == "text" then
          msg.content = kept[1].text or ""
        else
          msg.content = kept
        end
      end
    end
  end
  return stripped_any
end

function M._clean_api_messages(messages)
  local source_messages = vim.deepcopy(messages or {})
  M._strip_image_payloads_from_messages(source_messages)
  local save_messages = {}
  for _, msg in ipairs(source_messages) do
    if not (msg.role == "system" and (msg._is_direct_file_context or msg._is_web_search or msg._is_memory_context or msg._is_skills_context)) then
      local content = msg.content
      if msg.role == "assistant" then
        content = clean_reasoning_artifacts(content)
      end
      local clean = { role = msg.role, content = content }
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
  end
  return save_messages
end

function M._save_api_messages(config, record, messages)
  if not record or not record.id then return false end
  local store = M._store_for_record(config, record)
  store.save_meta({
    id = record.id,
    adapter = record.adapter,
    title = record.title,
    status = record.status or "active",
    created_at = record.created_at,
    cwd = record.cwd,
  })
  return store.save_messages(record.id, M._clean_api_messages(messages))
end

function M._load_api_messages(config, record)
  if not record or not record.id then return {} end
  local store = M._store_for_record(config, record)
  if store.has_messages(record.id) then
    return store.load_messages(record.id)
  end

  local ok_legacy, llama_session_mod = pcall(require, "neocode.llama_session")
  if ok_legacy and config and config.data_dir then
    return llama_session_mod.load(config.data_dir .. "/llama", record.id)
  end
  return {}
end

function M._append_transcript(config, record, event)
  if not record or not record.id or not event then return false end
  local store = M._store_for_record(config, record)
  return store.append_transcript(record.id, event)
end

function M._save_api_summary(config, record, summary)
  if not record or not record.id then return false end
  local store = M._store_for_record(config, record)
  return store.save_summary(record.id, summary or "")
end

function M.delete_from_disk(session_id, config)
  local all = M.load_all_from_disk(config)
  local filtered = {}
  for _, s in ipairs(all) do
    if s.id == session_id then
      local ok_store, store = pcall(M._store_for_record, config, s)
      if ok_store and store then
        pcall(function() store.delete_session(session_id) end)
      end
    else
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
      local ok_store, store = pcall(M._store_for_record, config, s)
      if ok_store and store then
        local meta = store.load_meta(session_id) or {}
        meta.id = meta.id or s.id
        meta.adapter = meta.adapter or s.adapter
        meta.status = meta.status or s.status
        meta.created_at = meta.created_at or s.created_at
        meta.cwd = meta.cwd or s.cwd
        meta.title = new_title
        store.save_meta(meta)
      end
      break
    end
  end
  _write_sessions_json(_sessions_path(config), all)
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
    if s.api_adapter and s.messages and #s.messages > 0 then
      M._save_api_messages(config, s, s.messages)
    end
    vim.notify("neocode: renamed session to '" .. s.title .. "'", vim.log.levels.INFO)
  end)
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

  local record = M._new_record(adapter.name, title)
  record.messages = {}
  record.api_adapter = adapter
  record.pending_image_b64 = nil
  record.cwd = require("neocode.context").find_project_root()
  M._add(record)
  _current_id = record.id

  local saved = M._load_api_messages(config, record)
  if #saved > 0 then
    record.messages = saved
  end

  local state = M._load_api_state(config, record)
  if type(state.tool_permissions) == "table" then
    record.tool_permissions = state.tool_permissions
  end

  local buf = chat_buffer.create(record.messages, { draft = true })
  record.bufnr = buf

  vim.cmd("vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  record.winid = win

  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].conceallevel = 2
  vim.wo[win].concealcursor = "nc"
  vim.wo[win].winbar = config.winbar or ""
  vim.wo[win].list = false
  M._refresh_api_chat(record, { draft = true, editable = true })
  vim.cmd("startinsert")

  M._register_api_keymaps(buf, record, config)
  -- Don't persist yet -- wait until first message is sent (see do_stream auto-title)

  -- Attach render-markdown.nvim (optional dep) so headings, bold, code fences,
  -- and tables render with conceal/highlights instead of raw syntax. Resume
  -- path does this too — keep them in sync.
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].filetype = "markdown"
      pcall(function() require("render-markdown").buf_attach(buf) end)
    end
  end)

end

-- Resume a saved API session by loading its messages from disk.
function M.resume_api(adapter, session_data, config)
  local chat_buffer = require("neocode.chat_buffer")

  -- Check if already in memory (avoid duplicates)
  local existing = M._get(session_data.id)
  if existing and existing.bufnr and vim.api.nvim_buf_is_valid(existing.bufnr) then
    _current_id = existing.id
    vim.api.nvim_set_current_buf(existing.bufnr)
    return
  end

  -- Remove stale entry if exists
  if existing then M._remove(session_data.id) end

  local record = {
    id            = session_data.id,
    adapter       = adapter.name,
    title         = session_data.title,
    status        = "active",
    created_at    = session_data.created_at,
    bufnr         = nil,
    winid         = nil,
    job_id        = nil,
    messages      = {},
    api_adapter   = adapter,
    pending_image_b64 = nil,
    cwd           = session_data.cwd or require("neocode.context").find_project_root(),
  }
  M._add(record)
  _current_id = record.id

  -- Load saved messages and clean up stale entries
  local saved = M._load_api_messages(config, record)
  if #saved > 0 then
    -- Filter out empty/broken messages from history
    local clean = {}
    for _, msg in ipairs(saved) do
      -- Skip empty assistant messages (leftover from tool-call rounds)
      if msg.role == "assistant" and (msg.content == nil or msg.content == "") and not msg.tool_calls then
        goto skip_msg
      end
      -- Skip auto-continue "Continue." messages
      if msg.role == "user" and msg.content == "Continue." then
        goto skip_msg
      end
      table.insert(clean, msg)
      ::skip_msg::
    end
    record.messages = clean
  end

  local state = M._load_api_state(config, record)
  if type(state.tool_permissions) == "table" then
    record.tool_permissions = state.tool_permissions
  end

  local buf = chat_buffer.create(record.messages, { draft = true })
  record.bufnr = buf

  -- Reuse existing NeoCode window if possible, otherwise vsplit
  local win = nil
  local current = M._current()
  if current and current.winid and vim.api.nvim_win_is_valid(current.winid) then
    win = current.winid
  else
    -- Check if current window is a NeoCode buffer
    local cur_win = vim.api.nvim_get_current_win()
    local cur_buf = vim.api.nvim_win_get_buf(cur_win)
    if vim.bo[cur_buf].buftype == "nofile" then
      win = cur_win
    else
      vim.cmd("vsplit")
      win = vim.api.nvim_get_current_win()
    end
  end

  vim.api.nvim_win_set_buf(win, buf)
  record.winid = win

  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].conceallevel = 2
  vim.wo[win].concealcursor = "nc"
  vim.wo[win].winbar = config.winbar or ""
  vim.wo[win].list = false
  M._refresh_api_chat(record, { draft = true, editable = true })

  -- Update status and persist
  record.status = "active"
  M._register_api_keymaps(buf, record, config)
  M._persist(config)

  -- Scroll to bottom
  local total = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_win_set_cursor(win, { total, 0 })

  -- Re-trigger markdown rendering after buffer is displayed
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].filetype = "markdown"
      pcall(function() require("render-markdown").buf_attach(buf) end)
    end
  end)

  local msg_count = #record.messages
  vim.notify("neocode: resumed session '" .. record.title .. "' (" .. msg_count .. " messages)", vim.log.levels.INFO)
end

function M._register_api_keymaps(buf, record, config)
  local opts = { buffer = buf, silent = true }

  vim.keymap.set("n", "i", function()
    if vim.bo[buf].modifiable then
      vim.cmd("startinsert")
      return
    end
    M._open_api_input(record, config)
  end, opts)

  local function send_inline_draft()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = M._api_inline_draft_text_from_lines(lines)
    if text == "" then return end
    vim.bo[buf].modifiable = false
    M._open_api_input(record, config, { initial_lines = M._api_input_lines_from_text(text), auto_send = true })
  end

  vim.keymap.set({ "i", "n" }, "<C-s>", send_inline_draft, opts)
  vim.keymap.set({ "i", "n" }, "<C-CR>", send_inline_draft, opts)
  vim.keymap.set({ "i", "n" }, "<M-CR>", send_inline_draft, opts)

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
  vim.keymap.set("n", "R", function() M.rename_current(config) end, opts)

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
  local cfg = M._compact_endpoint_config(record)

  if not cfg then
    vim.notify("neocode: compact requires an API adapter with base_url and model", vim.log.levels.WARN)
    return false
  end

  record._auto_compact_running = true
  record._auto_compact_pending = false

  if #record.messages < 3 then
    record._auto_compact_running = false
    vim.notify("neocode: nothing to compact", vim.log.levels.INFO)
    return
  end

  local auto_cfg = config and config.auto_compact or {}
  local recent_messages = M._auto_compact_recent_messages(record.messages, auto_cfg.preserve_recent_turns or 0)
  local summary_source_messages = M._auto_compact_messages_to_summarize(record.messages, auto_cfg.preserve_recent_turns or 0)

  -- Show compacting indicator
  vim.bo[record.bufnr].modifiable = true
  local lc = vim.api.nvim_buf_line_count(record.bufnr)
  vim.api.nvim_buf_set_lines(record.bufnr, lc, lc, false, { "", "🗜️ Compacting conversation..." })
  vim.bo[record.bufnr].modifiable = false

  -- Build summary request: ask the model to summarize
  local conversation_text = {}
  for _, msg in ipairs(summary_source_messages) do
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
    { role = "system", content = COMPACT_SUMMARY_INSTRUCTIONS },
    { role = "user", content = table.concat(conversation_text, "\n") },
  }

  local url = M._compact_chat_url(record)
  local payload = vim.fn.json_encode({
    model = cfg.model,
    messages = summary_prompt,
    stream = false,
    temperature = 0.3,
    max_tokens = 900,
    enable_thinking = false,
    chat_template_kwargs = { enable_thinking = false },
  })

  local compact_job_id = vim.fn.jobstart({
    "curl", "--silent",
    "-X", "POST", url,
    "-H", "Content-Type: application/json",
    "-d", payload,
  }, {
    stdout_buffered = true,
    on_exit = function(_, code)
      if code ~= 0 then
        record._auto_compact_running = false
      end
    end,
    on_stdout = function(_, data)
      vim.schedule(function()
        local raw = table.concat(data or {}, "")
        if raw == "" then
          record._auto_compact_running = false
          vim.notify("neocode: compact failed — no response from model (is it running?)", vim.log.levels.WARN)
          if record.bufnr and vim.api.nvim_buf_is_valid(record.bufnr) then
            M._refresh_api_chat(record, { draft = true, editable = true })
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
          summary = M._ensure_structured_compact_summary(summary)
        elseif ok and result and result.error then
          record._auto_compact_running = false
          vim.notify("neocode: compact failed — " .. tostring(result.error.message or result.error), vim.log.levels.WARN)
          if record.bufnr and vim.api.nvim_buf_is_valid(record.bufnr) then
            M._refresh_api_chat(record, { draft = true, editable = true })
          end
          return
        end

        if summary == "" then
          record._auto_compact_running = false
          vim.notify("neocode: compact failed — model returned empty summary (try again)", vim.log.levels.WARN)
          -- Remove compacting indicator
          if record.bufnr and vim.api.nvim_buf_is_valid(record.bufnr) then
            M._refresh_api_chat(record, { draft = true, editable = true })
          end
          return
        end

        local old_count = #record.messages

        -- Replace all messages with the summary as a conversation exchange
        record.messages = {
          { role = "user", content = "Summarize our conversation so far." },
          { role = "assistant", content = "Here is a summary of our conversation:\n\n" .. summary },
        }
        for _, msg in ipairs(recent_messages) do
          table.insert(record.messages, msg)
        end
        M._save_api_summary(config, record, summary)
        M._append_transcript(config, record, {
          role = "system",
          kind = "compact",
          content = summary,
          old_message_count = old_count,
        })

        -- Save compacted prompt-ready history without deleting the raw transcript.
        M._save_api_messages(config, record, record.messages)

        record._auto_compact_last_usage = nil
        record._auto_compact_running = false

        vim.notify("neocode: conversation compacted", vim.log.levels.INFO)
        M._refresh_api_chat(record, { draft = true, editable = true })
      end)
    end,
  })
  if compact_job_id <= 0 then
    record._auto_compact_running = false
    vim.notify("neocode: compact failed — could not start curl", vim.log.levels.WARN)
    return false
  end
  return true
end

function M._open_api_input(record, config, opts)
  opts = opts or {}
  local chat_buffer = require("neocode.chat_buffer")
  local llama = record.api_adapter

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype  = "markdown"
  vim.bo[buf].bufhidden = "wipe"

  local width  = math.floor(vim.o.columns * 0.7)
  local height = math.floor(vim.o.lines * 0.3)
  local row    = math.floor((vim.o.lines - height) / 2)
  local col    = math.floor((vim.o.columns - width) / 2)

  local title = " NeoCode Input — <C-s>/<C-CR>/<M-CR> send · <C-v> paste image · <Esc> cancel "
  if record.pending_image_b64 then
    title = " NeoCode Input [image attached] — <C-s>/<C-CR>/<M-CR> send · <Esc> cancel "
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
  local initial_lines = opts.initial_lines or { "Me:", "" }
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial_lines)
  vim.api.nvim_win_set_cursor(win, { math.max(2, #initial_lines), 0 })
  vim.cmd("startinsert")

  local function send_and_close()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = M._api_input_text_from_lines(lines)
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

    local rename_title = text:match("^%s*/rename%s+(.+)%s*$")
    if rename_title then
      if M._rename_record(record, rename_title) then
        M._persist(config)
        if record.messages and #record.messages > 0 then
          M._save_api_messages(config, record, record.messages)
        end
        M._refresh_api_chat(record, { draft = true, editable = true })
        vim.notify("neocode: renamed session to '" .. record.title .. "'", vim.log.levels.INFO)
      end
      return
    end

    if M._handle_local_command(text, record, config) then
      return
    end

    -- Age any existing web-search system messages and drop stale ones.
    -- Web search results are only relevant to the turn that requested them
      -- plus one follow-up turn; anything older is dead context that burns
      -- prefill time every round. Messages are tagged with _is_web_search and
      -- _age when injected in the search callback below.
      for i = #record.messages, 1, -1 do
        local msg = record.messages[i]
        if msg.role == "system" and (msg._is_direct_file_context or msg._is_memory_context or msg._is_skills_context) then
          table.remove(record.messages, i)
        elseif msg.role == "system" and msg._is_web_search then
          msg._age = (msg._age or 0) + 1
          if msg._age >= 2 then
            table.remove(record.messages, i)
        end
      end
    end

    local web_search = require("neocode.web_search")

    local web_search_active = false

    local function do_stream()
      local direct_read_content = nil
      if not web_search_active then
        local direct_read_path = M._direct_read_fast_path(text, record.cwd)
        if direct_read_path and vim.fn.filereadable(direct_read_path) == 1 then
          direct_read_content = read_direct_file(direct_read_path)
          if direct_read_content then
            table.insert(record.messages, M._build_direct_file_context_message(direct_read_path, direct_read_content))
          end
        end
      end

      local memory_context = M._build_memory_context(config, record.cwd)
      if memory_context then
        table.insert(record.messages, memory_context)
      end
      local skills_context = M._build_skills_context(config)
      if skills_context then
        table.insert(record.messages, skills_context)
      end

      local is_first_user_message = not has_user_message(record.messages)
      M._strip_image_payloads_from_messages(record.messages)
      local user_msg = llama._build_user_message(text, record.pending_image_b64)
      record.pending_image_b64 = nil
      table.insert(record.messages, user_msg)
      M._append_transcript(config, record, user_msg)

      -- Auto-title from first user message
      M._auto_title_from_first_user_message(record, text, config, is_first_user_message)

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
            -- Prefer real prefill progress from llama-server /slots polling;
            -- fall back to live decode stats (rare — only fires if the model
            -- emits content *inside* a <think> block before we flip phase).
            local extra = ""
            local prog = llama._prefill_progress
            if prog and prog.pct and prog.n_total > 0 then
              extra = string.format(" · %d%% (%d/%d)",
                math.floor(prog.pct * 100 + 0.5), prog.n_done, prog.n_total)
            else
              local live = llama._live_stats
              if live and live.token_count and live.token_count > 0 then
                extra = string.format(" · %d tokens", live.token_count)
                if live.tps and live.tps > 0 then
                  extra = extra .. string.format(" · %.1f t/s", live.tps)
                end
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

      -- Use native local workspace tools for project prompts.
      local tools = nil
      if not direct_read_content and not web_search_active then
        tools = M._build_project_tools(text, record.cwd)
      end

      local auto_continue_count = 0
      local max_auto_continues = 3
      local tool_stream_opts = nil

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
            if tool_msg_count > 3 and #(record.messages[i].content or "") > 200 then
              record.messages[i].content = record.messages[i].content:sub(1, 150) .. "\n...[truncated]"
            end
          end
        end

        -- Detect truncated/incomplete response and auto-continue
        local clean = (response_text or ""):gsub("<think>.-</think>", ""):gsub("</?tool_call>", ""):gsub("^%s+", ""):gsub("%s+$", "")
        local is_truncated = false
        if clean ~= "" and auto_continue_count < max_auto_continues then
          -- Check for signs of truncation (be conservative to avoid false positives)
          local last_line = clean:match("[^\n]*$") or ""
          local has_unexecuted_tool = response_text:match("<tool_call>")
            or response_text:match('%{"function":')

          -- Check if this response came after tool calls (model should analyze results)
          local had_tool_calls = false
          for i = #record.messages, 1, -1 do
            if record.messages[i].role == "tool" then had_tool_calls = true; break end
            if record.messages[i].role == "user" then break end
          end

          -- Only auto-continue for clear truncation signs
          if has_unexecuted_tool then
            is_truncated = true
          elseif #clean < 20 and not clean:match("[%.%?!]") then
            is_truncated = true
          elseif had_tool_calls and #clean < 100 then
            -- Model got tool results but barely responded -- needs to continue
            is_truncated = true
          elseif last_line:match("^%d+%.%s*$") or last_line:match("^%-%s*$") or last_line:match("^%*%s*$") then
            is_truncated = true
          end
        end

        if is_truncated then
          auto_continue_count = auto_continue_count + 1
          -- Auto-continue: add a continue prompt
          table.insert(record.messages, { role = "user", content = "Continue." })

          -- Show indicator
          if record.bufnr and vim.api.nvim_buf_is_valid(record.bufnr) then
            chat_buffer.refresh(record.bufnr, record.messages)
            vim.bo[record.bufnr].modifiable = true
            local lc = vim.api.nvim_buf_line_count(record.bufnr)
            vim.api.nvim_buf_set_lines(record.bufnr, lc, lc, false, {
              "", "### Assistant", "", "💭 Continuing..."
            })
            vim.bo[record.bufnr].modifiable = false
          end

          -- Restart spinner and stream
          spinner_active = true
          spinner_phase = "thinking"
          spinner_tool_name = nil
          phase_start = vim.uv.hrtime()

          table.insert(record.messages, { role = "assistant", content = "" })
          local function on_continued(cont_text, cont_stats)
            -- Merge continued response
            for i = #record.messages, 1, -1 do
              if record.messages[i].role == "assistant" then
                record.messages[i].content = cont_text
                record.messages[i]._stats = cont_stats
                break
              end
            end
            -- Check again for truncation (recursive via on_complete)
            on_complete(cont_text, cont_stats, nil)
          end
          if tools and #tools > 0 and tool_stream_opts then
            record.job_id = llama.stream_with_tools(record.messages, record.bufnr, on_continued, tool_stream_opts)
          else
            record.job_id = llama.stream(record.messages, record.bufnr, on_continued)
          end
          return
        end

        -- Response complete
        auto_continue_count = 0
        record.job_id = nil
        M._append_transcript(config, record, {
          role = "assistant",
          content = response_text,
          _stats = stats,
        })

        M._strip_image_payloads_from_messages(record.messages)

        M._refresh_api_chat(record, { draft = true, editable = true })
        vim.cmd("startinsert")

        M._save_api_messages(config, record, record.messages)

        if M._mark_auto_compact_if_needed(config, record, stats) then
          local usage = record._auto_compact_last_usage or {}
          if usage.used_tokens and usage.context_size then
            vim.notify(
              string.format("neocode: auto-compacting conversation (%d/%d context)", usage.used_tokens, usage.context_size),
              vim.log.levels.INFO
            )
          end
          M._compact_session(record, config)
        end
      end

      if tools and #tools > 0 then
        -- Use agentic tool-call loop
        local ok_local, local_tools = pcall(require, "neocode.local_tools")

        tool_stream_opts = {
          tools = tools,
          cwd = record.cwd,
          on_tool_call = function(tool_call, callback)
            local fn = tool_call["function"] or {}
            local tool_name = (fn.name or ""):match("__(.+)$") or fn.name or "unknown"

            spinner_phase = "tool"
            spinner_tool_name = tool_name
            phase_start = vim.uv.hrtime()

            -- Resolve relative paths in tool arguments to session cwd
            local function resolve_paths(tc)
              local tc_fn = tc["function"] or {}
              local ok_a, a = pcall(vim.fn.json_decode, tc_fn.arguments or "{}")
              if not ok_a or type(a) ~= "table" then return tc end
              local cwd = record.cwd or vim.fn.getcwd()
              local home = vim.fn.expand("~")
              local changed = false
              for _, key in ipairs({ "path", "file", "directory" }) do
                if a[key] and type(a[key]) == "string" then
                  local p = a[key]
                  -- Fix hallucinated home dirs (model outputs /home/user/ on macOS)
                  if p:match("^/home/[^/]+/") then
                    p = p:gsub("^/home/[^/]+", home)
                    a[key] = p
                    changed = true
                  end
                  -- Resolve relative paths and ~ to absolute
                  if p == "." or p == "./" then
                    a[key] = cwd
                    changed = true
                  elseif not p:match("^/") and not p:match("^~") then
                    a[key] = cwd .. "/" .. p
                    changed = true
                  elseif p:match("^~/") then
                    a[key] = vim.fn.expand(p)
                    changed = true
                  end
                end
              end
              if changed then
                tc_fn.arguments = vim.fn.json_encode(a)
              end
              return tc
            end

            local resolved_tc = resolve_paths(tool_call)
            local resolved_fn = resolved_tc["function"] or {}
            if ok_local and local_tools.can_handle(resolved_fn.name) then
              local function execute_local_tool(allow_shell)
                local result, is_error = local_tools.execute(resolved_tc, { cwd = record.cwd, allow_shell = allow_shell })
                callback(result, is_error)
              end

              if local_tools.requires_permission and local_tools.requires_permission(resolved_tc) then
                M._request_tool_permission(record, resolved_tc, function(allowed)
                  if allowed then
                    execute_local_tool(true)
                  else
                    callback("Permission denied for tool: " .. tostring(resolved_fn.name or "unknown"), true)
                  end
                end, config)
              else
                execute_local_tool(false)
              end
              return
            end

            if resolved_fn.name == "neocode__web_search" then
              local ok_args, args = pcall(vim.fn.json_decode, resolved_fn.arguments or "{}")
              if not ok_args or type(args) ~= "table" then args = {} end
              local query = args.query or ""
              if query == "" then
                callback("Missing required web search query", true)
                return
              end
              web_search.search(query, function(results)
                if results then
                  callback(web_search.format_context(query, results), false)
                else
                  callback("No web search results found", true)
                end
              end)
              return
            end

            callback("Tool is not available: " .. tostring(resolved_fn.name or "unknown"), true)
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
            if status == "done" or status == "error" then
              M._append_transcript(config, record, {
                role = "tool",
                tool_call_id = tool_call.id,
                status = status,
                content = result_text,
              })
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
        }
        record.job_id = llama.stream_with_tools(record.messages, record.bufnr, on_complete, tool_stream_opts)
      else
        -- No tools: use normal streaming
        record.job_id = llama.stream(record.messages, record.bufnr, function(response_text, stats)
          on_complete(response_text, stats, nil)
        end)
      end
    end

    -- Auto-detect if web search is needed.
    if web_search.is_explicit(text) then
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
          -- Remove any previous web-search system messages (including stale
          -- ones the age prune missed) before injecting the new one.
          for i = #record.messages, 1, -1 do
            local m = record.messages[i]
            if m.role == "system" and (m._is_web_search or (m.content or ""):match("web search results")) then
              table.remove(record.messages, i)
            end
          end
          local ctx = web_search.format_context(query, results)
          table.insert(record.messages, {
            role = "system",
            content = ctx,
            _is_web_search = true,
            _age = 0,
          })
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
    record.pending_image_b64 = nil
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
      title = " NeoCode Input [image attached] — <C-s>/<C-CR>/<M-CR> send · <Esc> cancel ",
      title_pos = "center",
    })
    vim.notify("neocode: image attached", vim.log.levels.INFO)
  end

  local function cancel()
    vim.api.nvim_win_close(win, true)
  end

  vim.keymap.set({ "i", "n" }, "<C-s>",  send_and_close, { buffer = buf, silent = true })
  vim.keymap.set({ "i", "n" }, "<C-CR>", send_and_close, { buffer = buf, silent = true })
  vim.keymap.set({ "i", "n" }, "<M-CR>", send_and_close, { buffer = buf, silent = true })
  vim.keymap.set({ "i", "n" }, "<C-v>",  paste_image,    { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", cancel, { buffer = buf, silent = true })
  if opts.auto_send then send_and_close() end
end

function M._paste_image_api(record, config)
  local images = require("neocode.images")
  if record then
    record.pending_image_b64 = nil
  end
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
      M._save_api_messages(config, s, s.messages)
    end

    s.status = "closed"
    s.bufnr = nil
    s.job_id = nil
    -- Only persist if session had messages (don't save empty sessions)
    if s.messages and #s.messages > 0 then
      M._persist(config)
    end
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

  vim.keymap.set("n", "R", function() M.rename_current(config) end, opts)

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
