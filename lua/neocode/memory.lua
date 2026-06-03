local M = {}

local function sanitize_slug(value)
  local slug = tostring(value or "project"):gsub("[^%w%-_]+", "-"):gsub("%-+", "-")
  slug = slug:gsub("^%-", ""):gsub("%-$", "")
  if slug == "" then slug = "project" end
  return slug:lower()
end

local function project_key(cwd)
  local root = vim.fn.fnamemodify(cwd or vim.fn.getcwd(), ":p"):gsub("/$", "")
  local name = sanitize_slug(vim.fn.fnamemodify(root, ":t"))
  local hash = vim.fn.sha256(root):sub(1, 12)
  return name .. "-" .. hash
end

local function read_json(path)
  if vim.fn.filereadable(path) ~= 1 then return {} end
  local raw = table.concat(vim.fn.readfile(path), "\n")
  local ok, data = pcall(vim.fn.json_decode, raw)
  if ok and type(data) == "table" then return data end
  return {}
end

local function write_json(path, data)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({ vim.fn.json_encode(data) }, path)
  pcall(vim.fn.setfperm, vim.fn.fnamemodify(path, ":h"), "rwx------")
  pcall(vim.fn.setfperm, path, "rw-------")
end

function M.new(opts)
  opts = opts or {}
  local data_dir = opts.data_dir or (vim.fn.stdpath("data") .. "/neocode")
  local cwd = opts.cwd or vim.fn.getcwd()
  local key = project_key(cwd)
  local path = data_dir .. "/memory/projects/" .. key .. ".json"
  local store = {}

  function store.path()
    return path
  end

  function store.load()
    local data = read_json(path)
    return data.entries or {}
  end

  function store.save(entry)
    if type(entry) ~= "table" or type(entry.text) ~= "string" or entry.text == "" then
      return false
    end
    local data = read_json(path)
    data.project_root = cwd
    data.entries = data.entries or {}
    table.insert(data.entries, {
      text = entry.text,
      created_at = entry.created_at or os.time(),
    })
    write_json(path, data)
    return true
  end

  function store.context_message()
    local entries = store.load()
    if #entries == 0 then return nil end
    local lines = { "Project memory for this NeoCode session:" }
    for _, entry in ipairs(entries) do
      table.insert(lines, "- " .. entry.text)
    end
    return {
      role = "system",
      _is_memory_context = true,
      content = table.concat(lines, "\n"),
    }
  end

  return store
end

M._project_key = project_key

return M
