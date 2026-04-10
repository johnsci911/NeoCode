-- lua/neocode/context.lua
-- Reads project context files to give the LLM understanding of the codebase.
local M = {}

-- Files to look for, in priority order
M.context_files = {
  ".neocode.md",    -- NeoCode-specific project instructions
  "CLAUDE.md",      -- Claude Code conventions (reuse if exists)
  ".cursorrules",   -- Cursor rules (reuse if exists)
  ".github/copilot-instructions.md", -- GitHub Copilot instructions
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

  if #parts == 0 then return nil end
  return table.concat(parts, "\n\n")
end

return M
