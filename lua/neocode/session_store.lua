local M = {}

local function join(...)
  local parts = { ... }
  local path = table.concat(parts, "/")
  path = path:gsub("/+", "/")
  return path
end

local function basename(path)
  local clean = (path or "project"):gsub("/+$", "")
  local name = clean:match("([^/]+)$") or "project"
  name = name:lower():gsub("[^%w%-_]+", "-"):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")
  if name == "" then return "project" end
  return name
end

local function project_key(cwd)
  local root = cwd or vim.fn.getcwd()
  local hash = vim.fn.sha256(root):sub(1, 8)
  return hash .. "-" .. basename(root)
end

function M.is_valid_session_id(session_id)
  return type(session_id) == "string" and session_id:match("^[%w_-]+$") ~= nil
end

local function assert_session_id(session_id)
  if not M.is_valid_session_id(session_id) then
    error("invalid session id: " .. tostring(session_id), 2)
  end
end

local function ensure_dir(path)
  vim.fn.mkdir(path, "p")
  pcall(vim.fn.setfperm, path, "rwx------")
end

local function protect_file(path)
  pcall(vim.fn.setfperm, path, "rw-------")
end

local function write_json(path, value)
  local ok, encoded = pcall(vim.fn.json_encode, value)
  if not ok then return false end
  ensure_dir(vim.fn.fnamemodify(path, ":h"))
  local f = io.open(path, "w")
  if not f then return false end
  f:write(encoded)
  f:close()
  protect_file(path)
  return true
end

local function read_json(path, fallback)
  local f = io.open(path, "r")
  if not f then return fallback end
  local raw = f:read("*a")
  f:close()
  local ok, decoded = pcall(vim.fn.json_decode, raw)
  if ok and type(decoded) == "table" then return decoded end
  return fallback
end

local function json_exists(path)
  return vim.fn.filereadable(path) == 1
end

local function write_text(path, text)
  ensure_dir(vim.fn.fnamemodify(path, ":h"))
  local f = io.open(path, "w")
  if not f then return false end
  f:write(text or "")
  f:close()
  protect_file(path)
  return true
end

local function read_text(path)
  local f = io.open(path, "r")
  if not f then return "" end
  local raw = f:read("*a")
  f:close()
  return raw
end

function M.new(config)
  config = config or {}
  local data_dir = config.data_dir or vim.fn.stdpath("data") .. "/neocode"
  local cwd = config.cwd or vim.fn.getcwd()
  local key = project_key(cwd)
  local project_dir = join(data_dir, "projects", key)
  local sessions_dir = join(project_dir, "sessions")

  local store = {
    data_dir = data_dir,
    cwd = cwd,
    project_key = key,
    project_dir = project_dir,
    sessions_dir = sessions_dir,
  }

  function store.session_dir(session_id)
    assert_session_id(session_id)
    return join(sessions_dir, session_id)
  end

  function store.save_meta(meta)
    if not meta or not meta.id then return false end
    return write_json(join(store.session_dir(meta.id), "meta.json"), meta)
  end

  function store.load_meta(session_id)
    return read_json(join(store.session_dir(session_id), "meta.json"), nil)
  end

  function store.save_messages(session_id, messages)
    return write_json(join(store.session_dir(session_id), "messages.json"), messages or {})
  end

  function store.messages_path(session_id)
    return join(store.session_dir(session_id), "messages.json")
  end

  function store.has_messages(session_id)
    return json_exists(store.messages_path(session_id))
  end

  function store.load_messages(session_id)
    return read_json(store.messages_path(session_id), {})
  end

  function store.append_transcript(session_id, event)
    if not session_id or not event then return false end
    local path = join(store.session_dir(session_id), "transcript.jsonl")
    ensure_dir(vim.fn.fnamemodify(path, ":h"))
    local f = io.open(path, "a")
    if not f then return false end
    local item = vim.deepcopy(event)
    item.timestamp = item.timestamp or os.time()
    local ok, encoded = pcall(vim.fn.json_encode, item)
    if not ok then
      f:close()
      return false
    end
    f:write(encoded .. "\n")
    f:close()
    protect_file(path)
    return true
  end

  function store.save_summary(session_id, summary)
    return write_text(join(store.session_dir(session_id), "summary.md"), summary or "")
  end

  function store.load_summary(session_id)
    return read_text(join(store.session_dir(session_id), "summary.md"))
  end

  function store.save_state(session_id, state)
    return write_json(join(store.session_dir(session_id), "state.json"), state or {})
  end

  function store.load_state(session_id)
    return read_json(join(store.session_dir(session_id), "state.json"), {})
  end

  function store.delete_session(session_id)
    vim.fn.delete(store.session_dir(session_id), "rf")
  end

  return store
end

return M
