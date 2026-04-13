-- lua/neocode/mcp.lua
local M = {}

-- Safe name: replace non-alphanumeric chars with underscores
local function safe_name(s)
  return (s or ""):gsub("[^%w]", "_")
end

-- Ensure an empty table JSON-encodes as {} (dict) not [] (array).
-- Lua cannot distinguish empty array from empty dict, so vim.fn.json_encode({})
-- emits []. Qwen3-Coder's jinja chat template iterates tool.parameters.properties
-- with the |items filter, which crashes minja with "Unknown filter 'items' for
-- type Array" when properties is empty. vim.empty_dict() tags the table so the
-- encoder emits {} instead.
local function ensure_dict(t)
  if type(t) == "table" and next(t) == nil then
    return vim.empty_dict()
  end
  return t
end

-- Check if mcphub is installed and hub is ready.
function M.available()
  local ok, mcphub = pcall(require, "mcphub")
  if not ok then return false end
  local hub = mcphub.get_hub_instance()
  return hub ~= nil
end

-- Get the hub instance, or nil.
function M._hub()
  local ok, mcphub = pcall(require, "mcphub")
  if not ok then return nil end
  return mcphub.get_hub_instance()
end

-- Format one MCP tool as an OpenAI function-calling schema.
function M._format_tool_schema(tool)
  local params = tool.inputSchema or {
    type = "object",
    properties = vim.empty_dict(),
    required = {},
  }
  -- Normalize empty properties (from mcphub schemas or our fallback) so jinja
  -- templates that iterate with |items don't crash on a JSON array.
  if type(params) == "table" then
    params.properties = ensure_dict(params.properties)
  end
  return {
    type = "function",
    ["function"] = {
      name = safe_name(tool.server_name) .. "__" .. safe_name(tool.name),
      description = tool.description or tool.name,
      parameters = params,
    },
  }
end

-- Format one MCP resource as an OpenAI function-calling schema.
function M._format_resource_schema(resource)
  local uri_safe = safe_name(resource.uri)
  return {
    type = "function",
    ["function"] = {
      name = "mcp_resource__" .. safe_name(resource.server_name) .. "__" .. uri_safe,
      description = string.format(
        "Access resource: %s - %s (from %s)",
        resource.name or resource.uri,
        resource.description or "",
        resource.server_name
      ),
      parameters = {
        type = "object",
        properties = vim.empty_dict(),
        required = {},
      },
    },
  }
end

-- Format one MCP prompt as an OpenAI function-calling schema.
function M._format_prompt_schema(prompt)
  local props = {}
  local required = {}
  if prompt.arguments then
    for _, arg in ipairs(prompt.arguments) do
      props[arg.name] = {
        type = "string",
        description = arg.description or arg.name,
      }
      if arg.required then
        table.insert(required, arg.name)
      end
    end
  end
  return {
    type = "function",
    ["function"] = {
      name = "mcp_prompt__" .. safe_name(prompt.server_name) .. "__" .. safe_name(prompt.name),
      description = string.format(
        "Prompt template: %s - %s (from %s)",
        prompt.name,
        prompt.description or "",
        prompt.server_name
      ),
      parameters = {
        type = "object",
        properties = ensure_dict(props),
        required = required,
      },
    },
  }
end

-- Parse "server__tool" back to server_name, tool_name.
function M._parse_tool_name(name)
  local server, tool = name:match("^(.-)__(.+)$")
  return server, tool
end

-- Parse "mcp_resource__server__uri_safe" back to server_name, uri.
function M._parse_resource_name(name)
  local rest = name:match("^mcp_resource__(.+)$")
  if not rest then return nil, nil end
  local server, uri_safe = rest:match("^(.-)__(.+)$")
  return server, uri_safe
end

-- Parse "mcp_prompt__server__prompt" back to server_name, prompt_name.
function M._parse_prompt_name(name)
  local rest = name:match("^mcp_prompt__(.+)$")
  if not rest then return nil, nil end
  local server, prompt = rest:match("^(.-)__(.+)$")
  return server, prompt
end

-- Get all tools + resources + prompts as OpenAI function schemas.
-- Returns empty table if mcphub is not available.
function M.get_all_tools()
  local hub = M._hub()
  if not hub then return {} end

  local schemas = {}

  -- Tools
  local tools = hub:get_tools()
  for _, tool in ipairs(tools) do
    table.insert(schemas, M._format_tool_schema(tool))
  end

  -- Resources
  local resources = hub:get_resources()
  for _, resource in ipairs(resources) do
    table.insert(schemas, M._format_resource_schema(resource))
  end

  -- Prompts
  local prompts = hub:get_prompts()
  for _, prompt in ipairs(prompts) do
    table.insert(schemas, M._format_prompt_schema(prompt))
  end

  return schemas
end

-- Extract text from an mcphub response (handles multiple formats)
local function extract_response_text(res)
  if not res then return nil end
  -- Standard parsed format
  if res.text and res.text ~= "" then return res.text end
  -- Raw content array format
  if res.content and type(res.content) == "table" then
    local parts = {}
    for _, item in ipairs(res.content) do
      if type(item) == "table" and item.text then
        table.insert(parts, item.text)
      elseif type(item) == "string" then
        table.insert(parts, item)
      end
    end
    if #parts > 0 then return table.concat(parts, "\n") end
  end
  -- Single string response
  if type(res) == "string" and res ~= "" then return res end
  -- Try vim.inspect as last resort for debugging
  local inspected = vim.inspect(res)
  if #inspected > 10 and inspected ~= "{\n}" and inspected ~= "{}" then
    return inspected
  end
  return nil
end

-- Execute a tool call from the model. Routes to the correct handler based on name prefix.
-- tool_call: { id, function = { name, arguments } }
-- callback: function(result_text, is_error)
function M.execute_tool_call(tool_call, callback)
  local hub = M._hub()
  if not hub then
    callback("mcphub is not available", true)
    return
  end

  local fn = tool_call["function"] or tool_call
  local name = fn.name
  local args_str = fn.arguments or "{}"
  local ok_args, args = pcall(vim.fn.json_decode, args_str)
  if not ok_args then args = {} end

  if name:match("^mcp_resource__") then
    local server, uri_safe = M._parse_resource_name(name)
    if not server then
      callback("invalid resource name: " .. name, true)
      return
    end
    hub:access_resource(server, uri_safe, {
      parse_response = true,
      callback = function(res, err)
        vim.schedule(function()
          if err then
            callback("Error: " .. tostring(err), true)
          else
            local text = extract_response_text(res)
            callback(text or "(empty resource)", text == nil)
          end
        end)
      end,
    })
  elseif name:match("^mcp_prompt__") then
    local server, prompt_name = M._parse_prompt_name(name)
    if not server then
      callback("invalid prompt name: " .. name, true)
      return
    end
    hub:get_prompt(server, prompt_name, args, {
      parse_response = true,
      callback = function(res, err)
        vim.schedule(function()
          if err then
            callback("Error: " .. tostring(err), true)
          elseif res and res.messages then
            local parts = {}
            for _, msg in ipairs(res.messages) do
              local t = extract_response_text(msg.output or msg)
              if t then table.insert(parts, t) end
            end
            callback(#parts > 0 and table.concat(parts, "\n") or "(empty prompt)", #parts == 0)
          else
            callback("(empty prompt)", true)
          end
        end)
      end,
    })
  else
    -- Regular tool: "server__tool"
    local server, tool_name = M._parse_tool_name(name)
    if not server or not tool_name then
      callback("invalid tool name: " .. name, true)
      return
    end
    hub:call_tool(server, tool_name, args, {
      parse_response = true,
      callback = function(res, err)
        vim.schedule(function()
          if err then
            callback("Error: " .. tostring(err), true)
          else
            local text = extract_response_text(res)
            callback(text or "(empty result)", text == nil)
          end
        end)
      end,
    })
  end
end

-- Extract a human-readable summary of tool call args.
function M.summarize_args(args_str)
  local ok, args = pcall(vim.fn.json_decode, args_str or "{}")
  if not ok or type(args) ~= "table" then return "" end
  local parts = {}
  for k, v in pairs(args) do
    local val = type(v) == "string" and v or vim.fn.json_encode(v)
    if #val > 40 then val = val:sub(1, 37) .. "..." end
    table.insert(parts, k .. '="' .. val .. '"')
    if #parts >= 2 then break end
  end
  return table.concat(parts, " ")
end

-- Get the human-readable tool display name from a namespaced function name.
function M.display_name(name)
  if name:match("^mcp_resource__") then
    local _, uri = M._parse_resource_name(name)
    return "Access " .. (uri or name)
  elseif name:match("^mcp_prompt__") then
    local _, prompt = M._parse_prompt_name(name)
    return "Prompt " .. (prompt or name)
  else
    local _, tool = M._parse_tool_name(name)
    return tool or name
  end
end

return M
