-- lua/neocode/local_tools.lua
-- Native local workspace tools for hot-path project operations.
local M = {}

local IGNORED_NAMES = {
  [".git"] = true,
  ["node_modules"] = true,
  ["vendor"] = true,
  ["dist"] = true,
  ["build"] = true,
  ["target"] = true,
  ["__pycache__"] = true,
}

local TEXT_EXTENSIONS = {
  [""] = true,
  [".c"] = true,
  [".cc"] = true,
  [".cfg"] = true,
  [".cmake"] = true,
  [".cpp"] = true,
  [".css"] = true,
  [".h"] = true,
  [".hpp"] = true,
  [".html"] = true,
  [".ini"] = true,
  [".js"] = true,
  [".json"] = true,
  [".lua"] = true,
  [".md"] = true,
  [".py"] = true,
  [".rs"] = true,
  [".sh"] = true,
  [".toml"] = true,
  [".ts"] = true,
  [".tsx"] = true,
  [".txt"] = true,
  [".vim"] = true,
  [".yaml"] = true,
  [".yml"] = true,
}

local SAFE_SHELL_COMMANDS = {
  ["pwd"] = true,
  ["ls"] = true,
  ["ls -la"] = true,
  ["ls -al"] = true,
  ["git status"] = true,
  ["git status --short"] = true,
  ["git diff --stat"] = true,
}

local INTERACTIVE_COMMAND_PATTERNS = {
  "^%s*vim%f[%W]",
  "^%s*nvim%f[%W]",
  "^%s*vi%f[%W]",
  "^%s*nano%f[%W]",
  "^%s*less%f[%W]",
  "^%s*more%f[%W]",
  "^%s*top%f[%W]",
  "^%s*htop%f[%W]",
  "^%s*ssh%f[%W]",
  "^%s*mysql%f[%W]",
  "^%s*psql%f[%W]",
  "^%s*python%s*$",
  "^%s*node%s*$",
  "^%s*irb%s*$",
}

local function uv()
  return vim.uv or vim.loop
end

local function is_ignored(name)
  return IGNORED_NAMES[name] or false
end

local function normalize_root(cwd)
  local root = cwd or vim.fn.getcwd()
  return uv().fs_realpath(root) or vim.fn.fnamemodify(root, ":p"):gsub("/$", "")
end

local function resolve_path(path, cwd)
  local root = normalize_root(cwd)
  local p = path or "."
  if p == "" or p == "." or p == "./" then
    p = root
  elseif p:match("^~/") then
    p = vim.fn.expand(p)
  elseif not p:match("^/") then
    p = root .. "/" .. p
  end

  local real = uv().fs_realpath(p)
  if not real then
    return nil, "path not found: " .. tostring(path or ".")
  end

  if real == root or real:sub(1, #root + 1) == root .. "/" then
    return real, nil, root
  end

  return nil, "path is outside workspace: " .. tostring(path or ".")
end

local function relpath(path, root)
  if path == root then return "." end
  if path:sub(1, #root + 1) == root .. "/" then
    return path:sub(#root + 2)
  end
  return path
end

local function read_text(path, max_chars)
  local f = io.open(path, "rb")
  if not f then return nil, "could not open file" end
  local data = f:read("*a") or ""
  f:close()
  if data:find("\0", 1, true) then
    return nil, "file appears to be binary"
  end
  local truncated = false
  if #data > max_chars then
    data = data:sub(1, max_chars)
    truncated = true
  end
  return data, nil, truncated
end

local function file_extension(path)
  return (path:match("(%.[^%.%/]+)$") or ""):lower()
end

local function is_text_file(path)
  local name = vim.fn.fnamemodify(path, ":t")
  if name == "README" or name == "Makefile" or name == "Dockerfile" or name == "LICENSE" then
    return true
  end
  return TEXT_EXTENSIONS[file_extension(path)] or false
end

local function schema(name, description, properties, required)
  return {
    type = "function",
    ["function"] = {
      name = "neocode__" .. name,
      description = description,
      parameters = {
        type = "object",
        properties = properties,
        required = required or {},
        additionalProperties = false,
      },
    },
  }
end

function M.get_tools()
  return {
    schema("read_file", "Read one text file from the local workspace.", {
      path = { type = "string", description = "Workspace-relative or absolute path inside the workspace." },
      max_chars = { type = "number", description = "Maximum characters to return. Default 12000." },
    }, { "path" }),
    schema("list_directory", "List files in a local workspace directory.", {
      path = { type = "string", description = "Workspace-relative directory path. Default ." },
    }, {}),
    schema("search_files", "Search local workspace text files for a plain-text query.", {
      query = { type = "string", description = "Plain text to search for." },
      path = { type = "string", description = "Workspace-relative directory path. Default ." },
      max_results = { type = "number", description = "Maximum matches to return. Default 50." },
      max_files = { type = "number", description = "Maximum text files to scan. Default 500." },
    }, { "query" }),
    schema("run_shell_command", "Run a shell command in the local workspace. Unsafe commands require user approval.", {
      command = { type = "string", description = "Shell command to run." },
    }, { "command" }),
  }
end

function M.can_handle(name)
  return name == "neocode__read_file"
    or name == "neocode__list_directory"
    or name == "neocode__search_files"
    or name == "neocode__run_shell_command"
end

local function parse_args(tool_call)
  local fn = tool_call["function"] or tool_call
  local ok, args = pcall(vim.fn.json_decode, fn.arguments or "{}")
  if not ok or type(args) ~= "table" then
    return nil, "invalid JSON arguments"
  end
  return args, nil
end

local function normalize_command(command)
  return tostring(command or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
end

function M.is_safe_shell_command(command)
  return SAFE_SHELL_COMMANDS[normalize_command(command)] == true
end

function M.is_interactive_shell_command(command)
  local normalized = normalize_command(command)
  for _, pattern in ipairs(INTERACTIVE_COMMAND_PATTERNS) do
    if normalized:match(pattern) then return true end
  end
  return false
end

function M.requires_permission(tool_call)
  local fn = tool_call["function"] or tool_call
  if fn.name ~= "neocode__run_shell_command" then return false end
  local args = parse_args(tool_call)
  if type(args) ~= "table" then return true end
  return not M.is_safe_shell_command(args.command)
end

local function read_file(args, opts)
  local path, err, root = resolve_path(args.path, opts.cwd)
  if not path then return "Error: " .. err, true end
  if vim.fn.filereadable(path) ~= 1 then return "Error: not a readable file: " .. tostring(args.path), true end
  local content, read_err, truncated = read_text(path, tonumber(args.max_chars) or 12000)
  if not content then return "Error: " .. read_err, true end
  local suffix = truncated and "\n\n[truncated]" or ""
  return string.format("File: %s\n```\n%s\n```%s", relpath(path, root), content, suffix), false
end

local function list_directory(args, opts)
  local path, err = resolve_path(args.path or ".", opts.cwd)
  if not path then return "Error: " .. err, true end
  if vim.fn.isdirectory(path) ~= 1 then return "Error: not a directory: " .. tostring(args.path or "."), true end

  local handle = uv().fs_scandir(path)
  if not handle then return "Error: could not list directory", true end
  local entries = {}
  while true do
    local name, kind = uv().fs_scandir_next(handle)
    if not name then break end
    if not is_ignored(name) then
      if kind == "directory" then name = name .. "/" end
      table.insert(entries, name)
    end
  end
  table.sort(entries)
  if #entries == 0 then return "(empty directory)", false end
  return table.concat(entries, "\n"), false
end

local function clamp_number(value, default, min, max)
  local n = tonumber(value) or default
  if n < min then return min end
  if n > max then return max end
  return math.floor(n)
end

local function scan_dir(dir, root, query, limits, results, state)
  if #results >= limits.max_results then return end
  if state.scanned_files >= limits.max_files then return end
  local handle = uv().fs_scandir(dir)
  if not handle then return end
  while #results < limits.max_results and state.scanned_files < limits.max_files do
    local name, kind = uv().fs_scandir_next(handle)
    if not name then break end
    if is_ignored(name) then goto continue end
    local path = dir .. "/" .. name
    if kind == "directory" then
      scan_dir(path, root, query, limits, results, state)
    elseif kind == "file" and is_text_file(path) then
      state.scanned_files = state.scanned_files + 1
      local content = read_text(path, 200000)
      if content then
        local line_no = 0
        for line in (content .. "\n"):gmatch("([^\n]*)\n") do
          line_no = line_no + 1
          if line:lower():find(query, 1, true) then
            table.insert(results, string.format("%s:%d: %s", relpath(path, root), line_no, line))
            if #results >= limits.max_results then return end
          end
        end
      end
    end
    ::continue::
  end
end

local function search_files(args, opts)
  local query = args.query
  if type(query) ~= "string" or query == "" then return "Error: missing query", true end
  local path, err, root = resolve_path(args.path or ".", opts.cwd)
  if not path then return "Error: " .. err, true end
  if vim.fn.isdirectory(path) ~= 1 then return "Error: not a directory: " .. tostring(args.path or "."), true end

  local results = {}
  local limits = {
    max_results = clamp_number(args.max_results, 50, 1, 200),
    max_files = clamp_number(args.max_files, 500, 1, 2000),
  }
  local state = { scanned_files = 0 }
  scan_dir(path, root, query:lower(), limits, results, state)
  if #results == 0 then return string.format("No matches found (searched %d files).", state.scanned_files), false end
  return table.concat(results, "\n"), false
end

local function run_shell_command(args, opts)
  local command = normalize_command(args.command)
  if command == "" then return "Error: missing command", true end
  if M.is_interactive_shell_command(command) then
    return "Error: blocked likely interactive shell command", true
  end
  if not M.is_safe_shell_command(command) and not opts.allow_shell then
    return "Error: shell command requires approval", true
  end

  local cwd = opts.cwd or vim.fn.getcwd()
  local result
  if vim.system then
    result = vim.system({ "sh", "-lc", command }, { cwd = cwd, text = true }):wait()
  else
    local old_cwd = vim.fn.getcwd()
    vim.cmd("lcd " .. vim.fn.fnameescape(cwd))
    local output = vim.fn.system({ "sh", "-lc", command })
    result = { code = vim.v.shell_error, stdout = output, stderr = "" }
    vim.cmd("lcd " .. vim.fn.fnameescape(old_cwd))
  end

  local body = result.stdout or ""
  local stderr = result.stderr or ""
  if stderr ~= "" then body = body .. (body ~= "" and "\n" or "") .. stderr end
  if body == "" then body = "(no output)" end
  if #body > 12000 then body = body:sub(1, 12000) .. "\n\n[truncated]" end
  if result.code ~= 0 then
    return string.format("Command failed (%d): %s\n%s", result.code or -1, command, body), true
  end
  return string.format("Command: %s\n%s", command, body), false
end

function M.execute(tool_call, opts)
  opts = opts or {}
  local fn = tool_call["function"] or tool_call
  local name = fn.name or ""
  if not M.can_handle(name) then return "Error: unsupported local tool: " .. name, true end
  local args, err = parse_args(tool_call)
  if not args then return "Error: " .. err, true end

  if name == "neocode__read_file" then
    return read_file(args, opts)
  elseif name == "neocode__list_directory" then
    return list_directory(args, opts)
  elseif name == "neocode__search_files" then
    return search_files(args, opts)
  elseif name == "neocode__run_shell_command" then
    return run_shell_command(args, opts)
  end
  return "Error: unknown local tool: " .. name, true
end

return M
