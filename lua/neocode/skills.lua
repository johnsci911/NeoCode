local M = {}

local function sanitize_name(name)
  local cleaned = tostring(name or ""):gsub("[^%w%-_]+", "-"):gsub("%-+", "-")
  cleaned = cleaned:gsub("^%-", ""):gsub("%-$", "")
  if cleaned == "" then return nil end
  return cleaned:lower()
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  if content then content = content:gsub("\n$", "") end
  return content
end

function M.new(opts)
  opts = opts or {}
  local data_dir = opts.data_dir or (vim.fn.stdpath("data") .. "/neocode")
  local dir = data_dir .. "/skills"
  local store = {}

  function store.path(name)
    local safe = sanitize_name(name)
    if not safe then return nil end
    return dir .. "/" .. safe .. ".md"
  end

  function store.save(name, content)
    local path = store.path(name)
    if not path or type(content) ~= "string" or content == "" then return false end
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile(vim.split(content, "\n", { plain = true }), path)
    pcall(vim.fn.setfperm, dir, "rwx------")
    pcall(vim.fn.setfperm, path, "rw-------")
    return true
  end

  function store.load(name)
    local path = store.path(name)
    if not path then return nil end
    return read_file(path)
  end

  function store.load_selected(selected)
    local result = {}
    for _, name in ipairs(selected or {}) do
      local safe = sanitize_name(name)
      local content = safe and store.load(safe) or nil
      if content and content ~= "" then
        table.insert(result, { name = safe, content = content })
      end
    end
    return result
  end

  function store.context_message(selected)
    local loaded = store.load_selected(selected)
    if #loaded == 0 then return nil end
    local lines = { "Selected NeoCode skills:" }
    for _, skill in ipairs(loaded) do
      table.insert(lines, "")
      table.insert(lines, "## Skill: " .. skill.name)
      table.insert(lines, skill.content)
    end
    return {
      role = "system",
      _is_skills_context = true,
      content = table.concat(lines, "\n"),
    }
  end

  return store
end

return M
