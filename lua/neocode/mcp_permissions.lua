-- lua/neocode/mcp_permissions.lua
local M = {}

-- In-memory permission table: "server::tool" -> level
local _perms = {}

function M._reset()
  _perms = {}
end

local function _key(server, tool)
  return server .. "::" .. tool
end

-- Check permission level for a tool. Returns level string or nil.
function M.check(server, tool)
  return _perms[_key(server, tool)]
end

-- Returns true if tool has any active permission.
function M.is_allowed(server, tool)
  return _perms[_key(server, tool)] ~= nil
end

-- Grant a permission level: "allowed_once", "allowed_session", "allowed_always"
function M.grant(server, tool, level)
  _perms[_key(server, tool)] = level
end

-- Consume a one-time permission. Session/always permissions survive.
function M.consume(server, tool)
  local k = _key(server, tool)
  if _perms[k] == "allowed_once" then
    _perms[k] = nil
  end
end

-- Prompt user for permission via vim.ui.select.
-- Calls callback(allowed: bool) after user responds.
function M.request(server, tool, args, callback)
  local level = M.check(server, tool)
  if level then
    callback(true)
    return
  end

  local args_str = vim.fn.json_encode(args or {})
  if #args_str > 120 then
    args_str = args_str:sub(1, 117) .. "..."
  end

  local prompt_text = string.format("%s::%s\nArgs: %s", server, tool, args_str)

  vim.ui.select(
    { "Allow once", "Allow for this session", "Always allow", "Deny" },
    { prompt = "NeoCode Tool Permission: " .. prompt_text },
    function(choice)
      if choice == "Allow once" then
        M.grant(server, tool, "allowed_once")
        callback(true)
      elseif choice == "Allow for this session" then
        M.grant(server, tool, "allowed_session")
        callback(true)
      elseif choice == "Always allow" then
        M.grant(server, tool, "allowed_always")
        callback(true)
      else
        callback(false)
      end
    end
  )
end

-- Save "allowed_always" permissions to disk.
function M.save(config)
  if not config or not config.data_dir then return end
  local always = {}
  for k, level in pairs(_perms) do
    if level == "allowed_always" then
      always[k] = level
    end
  end
  local ok, encoded = pcall(vim.fn.json_encode, always)
  if ok then
    local f = io.open(config.data_dir .. "/mcp_permissions.json", "w")
    if f then
      f:write(encoded)
      f:close()
    end
  end
end

-- Load persisted permissions from disk.
function M.load(config)
  if not config or not config.data_dir then return end
  local f = io.open(config.data_dir .. "/mcp_permissions.json")
  if not f then return end
  local ok, data = pcall(vim.fn.json_decode, f:read("*a"))
  f:close()
  if ok and type(data) == "table" then
    for k, level in pairs(data) do
      _perms[k] = level
    end
  end
end

return M
