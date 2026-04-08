-- Run this in Neovim with :luafile tests/test_mcp_live.lua
-- Tests the mcphub connection and filesystem tools

local ok, mcphub = pcall(require, "mcphub")
if not ok then
  print("ERROR: mcphub not installed")
  return
end

local hub = mcphub.get_hub_instance()
if not hub then
  print("ERROR: mcphub hub not ready (run :MCPHub first)")
  return
end

-- List available tools
print("=== Available Tools ===")
local tools = hub:get_tools()
for _, t in ipairs(tools) do
  print(string.format("  [%s] %s - %s", t.server_name, t.name, t.description or ""))
end

-- List available resources
print("\n=== Available Resources ===")
local resources = hub:get_resources()
for _, r in ipairs(resources) do
  print(string.format("  [%s] %s - %s", r.server_name, r.name or r.uri, r.description or ""))
end

-- Test list_directory
print("\n=== Test: list_directory /Users/johnkarlo/.config/nvim ===")
local res, err = hub:call_tool("filesystem", "list_directory", { path = "/Users/johnkarlo/.config/nvim" })
if err then
  print("ERROR: " .. tostring(err))
else
  print("Response type: " .. type(res))
  print("Response: " .. vim.inspect(res))
end

-- Test read_file
print("\n=== Test: read_file /Users/johnkarlo/.config/nvim/init.lua ===")
local res2, err2 = hub:call_tool("filesystem", "read_file", { path = "/Users/johnkarlo/.config/nvim/init.lua" })
if err2 then
  print("ERROR: " .. tostring(err2))
else
  print("Response type: " .. type(res2))
  if res2 then
    print("Keys: " .. table.concat(vim.tbl_keys(res2), ", "))
    if res2.text then
      print("Text (first 200 chars): " .. res2.text:sub(1, 200))
    else
      print("No .text field! Full: " .. vim.inspect(res2):sub(1, 500))
    end
  end
end
