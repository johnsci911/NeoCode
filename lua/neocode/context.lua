-- lua/neocode/context.lua
-- Reads project context files to give the LLM understanding of the codebase.
local M = {}

-- Project root markers (searched upward from current buffer)
local ROOT_MARKERS = {
  ".git", ".neocode.md", "CLAUDE.md",
  "package.json", "composer.json", "Cargo.toml", "go.mod",
  "Gemfile", "pyproject.toml", "requirements.txt",
  "pom.xml", "build.gradle", "mix.exs", "pubspec.yaml",
  "CMakeLists.txt", "Makefile", "init.lua",
}

-- Find project root by searching upward from a starting directory.
-- Returns the first directory containing a root marker, or cwd as fallback.
function M.find_project_root()
  -- Start from current buffer's directory
  local buf_dir = vim.fn.expand("%:p:h")
  if buf_dir == "" or buf_dir == "." then
    buf_dir = vim.fn.getcwd()
  end

  local dir = buf_dir
  local home = vim.fn.expand("~")
  while dir and dir ~= "/" and dir ~= home do
    for _, marker in ipairs(ROOT_MARKERS) do
      local path = dir .. "/" .. marker
      if vim.fn.filereadable(path) == 1 or vim.fn.isdirectory(path) == 1 then
        return dir
      end
    end
    dir = vim.fn.fnamemodify(dir, ":h")
  end

  -- Fallback to cwd
  return vim.fn.getcwd()
end

-- Files to look for, in priority order
M.context_files = {
  -- NeoCode
  ".neocode.md",
  -- Claude Code
  "CLAUDE.md",
  ".claude/instructions.md",
  -- Cursor
  ".cursorrules",
  ".cursor/rules/project.mdc",
  -- GitHub Copilot
  ".github/copilot-instructions.md",
  -- Windsurf / Codeium
  ".windsurfrules",
  -- Cline
  ".clinerules",
  -- Aider
  ".aider.conf.yml",
  -- Codex
  "AGENTS.md",
  -- Gemini
  "GEMINI.md",
  -- Generic
  ".ai-instructions.md",
  "AI.md",
}

-- Read a file and return its content, or nil
local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  if content and #content > 0 then return content end
  return nil
end

-- Gather project context from the given directory.
-- Returns a string with all context, or nil if nothing found.
function M.gather(cwd)
  if not cwd then return nil end
  local parts = {}

  -- Read project instruction files
  for _, filename in ipairs(M.context_files) do
    local content = read_file(cwd .. "/" .. filename)
    if content then
      -- Limit size to prevent context overflow
      if #content > 3000 then
        content = content:sub(1, 3000) .. "\n...[truncated]"
      end
      table.insert(parts, string.format("### Project Instructions (%s):\n%s", filename, content))
    end
  end

  -- Read README.md for project overview (first 100 lines)
  local readme = read_file(cwd .. "/README.md")
  if readme then
    local lines = {}
    local count = 0
    for line in (readme .. "\n"):gmatch("([^\n]*)\n") do
      count = count + 1
      if count > 100 then
        table.insert(lines, "...[truncated]")
        break
      end
      table.insert(lines, line)
    end
    table.insert(parts, "### Project README:\n" .. table.concat(lines, "\n"))
  end

  -- Read .neocode/skills/*.md if directory exists
  local skills_dir = cwd .. "/.neocode/skills"
  local uv = vim.uv or vim.loop
  local handle = uv.fs_scandir(skills_dir)
  if handle then
    while true do
      local name, kind = uv.fs_scandir_next(handle)
      if not name then break end
      if kind == "file" and name:match("%.md$") then
        local content = read_file(skills_dir .. "/" .. name)
        if content then
          if #content > 2000 then
            content = content:sub(1, 2000) .. "\n...[truncated]"
          end
          table.insert(parts, string.format("### Skill: %s\n%s", name:gsub("%.md$", ""), content))
        end
      end
    end
  end

  -- Fallback: if no instruction files found, auto-detect project from metadata
  if #parts == 0 then
    local detected = {}

    -- Detect tech stack from package/config files
    local stack_files = {
      { file = "package.json",     lang = "JavaScript/TypeScript", tool = "npm" },
      { file = "yarn.lock",        lang = "JavaScript/TypeScript", tool = "yarn" },
      { file = "pnpm-lock.yaml",   lang = "JavaScript/TypeScript", tool = "pnpm" },
      { file = "bun.lockb",        lang = "JavaScript/TypeScript", tool = "bun" },
      { file = "tsconfig.json",    lang = "TypeScript" },
      { file = "composer.json",    lang = "PHP" },
      { file = "artisan",          lang = "PHP",                   framework = "Laravel" },
      { file = "Gemfile",          lang = "Ruby" },
      { file = "go.mod",           lang = "Go" },
      { file = "Cargo.toml",       lang = "Rust" },
      { file = "requirements.txt", lang = "Python" },
      { file = "pyproject.toml",   lang = "Python" },
      { file = "setup.py",         lang = "Python" },
      { file = "pom.xml",          lang = "Java",                  tool = "Maven" },
      { file = "build.gradle",     lang = "Java/Kotlin",           tool = "Gradle" },
      { file = "mix.exs",          lang = "Elixir" },
      { file = "pubspec.yaml",     lang = "Dart/Flutter" },
      { file = "CMakeLists.txt",   lang = "C/C++",                 tool = "CMake" },
      { file = "Makefile",         tool = "Make" },
      { file = "Dockerfile",       tool = "Docker" },
      { file = "docker-compose.yml", tool = "Docker Compose" },
      { file = ".env",             note = "has environment config" },
      { file = "init.lua",         lang = "Lua",                   framework = "Neovim plugin" },
    }

    local langs = {}
    local tools = {}
    local frameworks = {}
    for _, sf in ipairs(stack_files) do
      local exists = io.open(cwd .. "/" .. sf.file, "r")
      if exists then
        exists:close()
        if sf.lang then langs[sf.lang] = true end
        if sf.tool then tools[sf.tool] = true end
        if sf.framework then frameworks[sf.framework] = true end
      end
    end

    if next(langs) then
      table.insert(detected, "Languages: " .. table.concat(vim.tbl_keys(langs), ", "))
    end
    if next(frameworks) then
      table.insert(detected, "Framework: " .. table.concat(vim.tbl_keys(frameworks), ", "))
    end
    if next(tools) then
      table.insert(detected, "Tools: " .. table.concat(vim.tbl_keys(tools), ", "))
    end

    -- Read key metadata files for more context
    local pkg = read_file(cwd .. "/package.json")
    if pkg then
      local ok, data = pcall(vim.fn.json_decode, pkg)
      if ok and data then
        if data.name then table.insert(detected, "Project: " .. data.name) end
        if data.description then table.insert(detected, "Description: " .. data.description) end
        if data.scripts then
          local scripts = {}
          for k, _ in pairs(data.scripts) do
            table.insert(scripts, k)
            if #scripts >= 8 then break end
          end
          table.insert(detected, "npm scripts: " .. table.concat(scripts, ", "))
        end
      end
    end

    local composer = read_file(cwd .. "/composer.json")
    if composer then
      local ok, data = pcall(vim.fn.json_decode, composer)
      if ok and data then
        if data.name then table.insert(detected, "Project: " .. data.name) end
        if data.description then table.insert(detected, "Description: " .. data.description) end
      end
    end

    -- Build directory tree (2 levels deep, max 30 entries)
    local tree = {}
    local function scan_dir(dir, prefix, depth)
      if depth > 2 or #tree >= 30 then return end
      local uv = vim.uv or vim.loop
      local h = uv.fs_scandir(dir)
      if not h then return end
      while #tree < 30 do
        local name, kind = uv.fs_scandir_next(h)
        if not name then break end
        -- Skip hidden dirs, node_modules, vendor, etc.
        if name:match("^%.") or name == "node_modules" or name == "vendor"
          or name == "__pycache__" or name == ".git" or name == "dist"
          or name == "build" or name == "target" then
          goto skip
        end
        if kind == "directory" then
          table.insert(tree, prefix .. name .. "/")
          scan_dir(dir .. "/" .. name, prefix .. "  ", depth + 1)
        else
          table.insert(tree, prefix .. name)
        end
        ::skip::
      end
    end
    scan_dir(cwd, "", 1)

    if #tree > 0 then
      table.insert(detected, "Project structure:\n" .. table.concat(tree, "\n"))
    end

    if #detected > 0 then
      table.insert(parts, "### Auto-detected Project Info:\n" .. table.concat(detected, "\n"))
    end
  end

  if #parts == 0 then return nil end
  return table.concat(parts, "\n\n")
end

return M
