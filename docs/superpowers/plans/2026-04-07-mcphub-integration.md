# NeoCode x mcphub Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable NeoCode's Llama adapter to call MCP tools, read resources, and use prompts via mcphub.nvim with a Claude Code-style permission system.

**Architecture:** Two new modules (`mcp.lua`, `mcp_permissions.lua`) bridge NeoCode to mcphub. The llama adapter gains a `stream_with_tools()` function that handles the agentic tool-call loop. Session wires it all together, and chat_buffer renders tool calls as brief summaries.

**Tech Stack:** Lua (Neovim plugin), mcphub.nvim API, llama-server OpenAI-compatible API with native tool calling

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `lua/neocode/mcp_permissions.lua` | Create | Permission checking, granting, persistence |
| `lua/neocode/mcp.lua` | Create | mcphub bridge: schema fetching, tool/resource/prompt execution |
| `lua/neocode/adapters/llama.lua` | Modify | Add `stream_with_tools()` with agentic loop |
| `lua/neocode/chat_buffer.lua` | Modify | Render tool call summaries (Claude Code style) |
| `lua/neocode/session.lua` | Modify | Wire MCP into API session input flow |
| `lua/neocode/hints.lua` | Modify | Add MCP hint line |
| `tests/neocode/mcp_permissions_spec.lua` | Create | Permission unit tests |
| `tests/neocode/mcp_spec.lua` | Create | MCP bridge unit tests |

---

### Task 1: Permission Manager (`mcp_permissions.lua`)

**Files:**
- Create: `lua/neocode/mcp_permissions.lua`
- Test: `tests/neocode/mcp_permissions_spec.lua`

- [ ] **Step 1: Write failing tests for permission checking**

```lua
-- tests/neocode/mcp_permissions_spec.lua
local perms = require("neocode.mcp_permissions")

describe("mcp_permissions", function()
  before_each(function()
    perms._reset()
  end)

  it("returns nil for unknown tool", function()
    assert.is_nil(perms.check("server", "tool"))
  end)

  it("grant allowed_once is consumed after check_and_consume", function()
    perms.grant("server", "tool", "allowed_once")
    assert.equals("allowed_once", perms.check("server", "tool"))
    perms.consume("server", "tool")
    assert.is_nil(perms.check("server", "tool"))
  end)

  it("grant allowed_session persists across checks", function()
    perms.grant("server", "tool", "allowed_session")
    assert.equals("allowed_session", perms.check("server", "tool"))
    perms.consume("server", "tool")
    assert.equals("allowed_session", perms.check("server", "tool"))
  end)

  it("grant allowed_always persists across checks", function()
    perms.grant("server", "tool", "allowed_always")
    assert.equals("allowed_always", perms.check("server", "tool"))
    perms.consume("server", "tool")
    assert.equals("allowed_always", perms.check("server", "tool"))
  end)

  it("is_allowed returns true for granted permissions", function()
    perms.grant("server", "tool", "allowed_session")
    assert.is_true(perms.is_allowed("server", "tool"))
  end)

  it("is_allowed returns false for unknown tools", function()
    assert.is_false(perms.is_allowed("server", "tool"))
  end)
end)

describe("mcp_permissions persistence", function()
  local tmp_dir = "/tmp/neocode_test_perms_" .. tostring(os.time())

  before_each(function()
    perms._reset()
    vim.fn.mkdir(tmp_dir, "p")
  end)

  after_each(function()
    vim.fn.delete(tmp_dir, "rf")
  end)

  it("save writes only allowed_always to disk", function()
    perms.grant("srv1", "tool1", "allowed_always")
    perms.grant("srv2", "tool2", "allowed_session")
    perms.save({ data_dir = tmp_dir })

    local path = tmp_dir .. "/mcp_permissions.json"
    assert.equals(1, vim.fn.filereadable(path))

    local f = io.open(path)
    local content = f:read("*a")
    f:close()
    assert.is_truthy(content:find("srv1"))
    assert.is_falsy(content:find("srv2"))
  end)

  it("load restores allowed_always from disk", function()
    perms.grant("srv1", "tool1", "allowed_always")
    perms.save({ data_dir = tmp_dir })

    perms._reset()
    perms.load({ data_dir = tmp_dir })
    assert.equals("allowed_always", perms.check("srv1", "tool1"))
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/johnkarlo/Desktop/NeoCode && nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/neocode/mcp_permissions_spec.lua"`
Expected: FAIL with "module 'neocode.mcp_permissions' not found"

- [ ] **Step 3: Implement mcp_permissions.lua**

```lua
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/johnkarlo/Desktop/NeoCode && nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/neocode/mcp_permissions_spec.lua"`
Expected: All 8 tests PASS

- [ ] **Step 5: Commit**

```bash
cd /Users/johnkarlo/Desktop/NeoCode
git add lua/neocode/mcp_permissions.lua tests/neocode/mcp_permissions_spec.lua
git commit -m "Add MCP permission manager with persistence"
```

---

### Task 2: MCP Bridge (`mcp.lua`)

**Files:**
- Create: `lua/neocode/mcp.lua`
- Test: `tests/neocode/mcp_spec.lua`

- [ ] **Step 1: Write failing tests for tool schema formatting**

```lua
-- tests/neocode/mcp_spec.lua
local mcp = require("neocode.mcp")

describe("mcp schema formatting", function()
  it("formats a tool as OpenAI function schema", function()
    local tool = {
      name = "read_file",
      description = "Read a file",
      inputSchema = {
        type = "object",
        properties = {
          path = { type = "string", description = "File path" },
        },
        required = { "path" },
      },
      server_name = "filesystem",
    }
    local schema = mcp._format_tool_schema(tool)
    assert.equals("function", schema.type)
    assert.equals("filesystem__read_file", schema["function"].name)
    assert.equals("Read a file", schema["function"].description)
    assert.is_not_nil(schema["function"].parameters.properties.path)
  end)

  it("formats a resource as OpenAI function schema", function()
    local resource = {
      uri = "file:///project/README.md",
      name = "README",
      description = "Project readme",
      server_name = "filesystem",
    }
    local schema = mcp._format_resource_schema(resource)
    assert.equals("function", schema.type)
    assert.is_truthy(schema["function"].name:find("^mcp_resource__"))
    assert.is_truthy(schema["function"].description:find("README"))
  end)

  it("formats a prompt as OpenAI function schema", function()
    local prompt = {
      name = "code_review",
      description = "Review code",
      arguments = {
        { name = "file", description = "File to review", required = true },
      },
      server_name = "codetools",
    }
    local schema = mcp._format_prompt_schema(prompt)
    assert.equals("function", schema.type)
    assert.is_truthy(schema["function"].name:find("^mcp_prompt__"))
    assert.is_not_nil(schema["function"].parameters.properties.file)
  end)

  it("parses namespaced tool name back to server and tool", function()
    local server, tool = mcp._parse_tool_name("filesystem__read_file")
    assert.equals("filesystem", server)
    assert.equals("read_file", tool)
  end)

  it("parses resource tool name back to server and uri", function()
    local server, uri = mcp._parse_resource_name("mcp_resource__filesystem__file____project__README_md")
    assert.equals("filesystem", server)
    assert.is_not_nil(uri)
  end)

  it("parses prompt tool name back to server and prompt", function()
    local server, prompt = mcp._parse_prompt_name("mcp_prompt__codetools__code_review")
    assert.equals("codetools", server)
    assert.equals("code_review", prompt)
  end)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/johnkarlo/Desktop/NeoCode && nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/neocode/mcp_spec.lua"`
Expected: FAIL with "module 'neocode.mcp' not found"

- [ ] **Step 3: Implement mcp.lua**

```lua
-- lua/neocode/mcp.lua
local M = {}

-- Safe name: replace non-alphanumeric chars with underscores
local function safe_name(s)
  return (s or ""):gsub("[^%w]", "_")
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
  return {
    type = "function",
    ["function"] = {
      name = safe_name(tool.server_name) .. "__" .. safe_name(tool.name),
      description = tool.description or tool.name,
      parameters = tool.inputSchema or {
        type = "object",
        properties = {},
        required = {},
      },
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
        properties = {},
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
        properties = props,
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
    -- Reverse the safe_name encoding for uri (best-effort)
    hub:access_resource(server, uri_safe, {
      callback = function(res, err)
        vim.schedule(function()
          if err then
            callback("Error: " .. tostring(err), true)
          elseif res and res.text then
            callback(res.text, false)
          else
            callback("(empty resource)", false)
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
      callback = function(res, err)
        vim.schedule(function()
          if err then
            callback("Error: " .. tostring(err), true)
          elseif res and res.messages then
            local parts = {}
            for _, msg in ipairs(res.messages) do
              if msg.output and msg.output.text then
                table.insert(parts, msg.output.text)
              end
            end
            callback(table.concat(parts, "\n"), false)
          else
            callback("(empty prompt)", false)
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
      callback = function(res, err)
        vim.schedule(function()
          if err then
            callback("Error: " .. tostring(err), true)
          elseif res and res.text then
            callback(res.text, false)
          else
            callback("(empty result)", false)
          end
        end)
      end,
    })
  end
end

-- Extract a human-readable summary of tool call args.
-- Returns a short string like: path="src/main.lua"
function M.summarize_args(args_str)
  local ok, args = pcall(vim.fn.json_decode, args_str or "{}")
  if not ok or type(args) ~= "table" then return "" end
  local parts = {}
  for k, v in pairs(args) do
    local val = type(v) == "string" and v or vim.fn.json_encode(v)
    if #val > 40 then val = val:sub(1, 37) .. "..." end
    table.insert(parts, k .. '="' .. val .. '"')
    if #parts >= 2 then break end -- max 2 args shown
  end
  return table.concat(parts, " ")
end

-- Get the human-readable tool display name from a namespaced function name.
-- "filesystem__read_file" -> "Read file"
-- "mcp_resource__filesystem__readme" -> "Access readme"
-- "mcp_prompt__codetools__review" -> "Prompt review"
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/johnkarlo/Desktop/NeoCode && nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/neocode/mcp_spec.lua"`
Expected: All 6 tests PASS

- [ ] **Step 5: Commit**

```bash
cd /Users/johnkarlo/Desktop/NeoCode
git add lua/neocode/mcp.lua tests/neocode/mcp_spec.lua
git commit -m "Add MCP bridge module for mcphub integration"
```

---

### Task 3: Tool Calling in Llama Adapter

**Files:**
- Modify: `lua/neocode/adapters/llama.lua`

This task adds `stream_with_tools()` -- a new function that wraps the existing `stream()` with an agentic tool-call loop.

- [ ] **Step 1: Add tool call accumulation to stream()**

Modify `lua/neocode/adapters/llama.lua`. Add a 4th parameter `opts` to `stream()` and accumulate tool_calls from deltas.

In the `stream()` function signature, change:

```lua
function M.stream(messages, bufnr, on_done)
```

to:

```lua
function M.stream(messages, bufnr, on_done, opts)
```

In the payload construction, after `repeat_penalty`, add tools if provided:

```lua
  local request_body = {
    model = cfg.model,
    messages = filtered,
    stream = true,
    stream_options = { include_usage = true },
    temperature = cfg.temperature or 0.7,
    top_p = cfg.top_p or 0.9,
    repeat_penalty = cfg.repeat_penalty or 1.3,
  }

  -- Add tool schemas if provided
  opts = opts or {}
  if opts.tools and #opts.tools > 0 then
    request_body.tools = opts.tools
  end

  local payload = vim.fn.json_encode(request_body)
```

Add tool_calls accumulation state alongside the existing state vars:

```lua
  local accumulated_tool_calls = {}
  local finish_reason = nil
```

In the `on_stdout` handler, inside the `if ok and chunk and chunk.choices and chunk.choices[1]` block, after the existing content handling, add tool_calls accumulation:

```lua
          -- Accumulate tool_calls from delta
          if delta and delta.tool_calls then
            for _, tc in ipairs(delta.tool_calls) do
              local idx = (tc.index or 0) + 1 -- Lua 1-indexed
              if not accumulated_tool_calls[idx] then
                accumulated_tool_calls[idx] = {
                  id = tc.id or ("call_" .. idx),
                  type = "function",
                  ["function"] = { name = "", arguments = "" },
                }
              end
              local acc = accumulated_tool_calls[idx]
              if tc.id then acc.id = tc.id end
              if tc["function"] then
                if tc["function"].name then
                  acc["function"].name = acc["function"].name .. tc["function"].name
                end
                if tc["function"].arguments then
                  acc["function"].arguments = acc["function"].arguments .. tc["function"].arguments
                end
              end
            end
          end

          -- Track finish_reason
          if chunk.choices[1].finish_reason then
            finish_reason = chunk.choices[1].finish_reason
          end
```

In the `on_exit` handler, before calling `on_done`, check if we have tool calls:

```lua
        -- If model requested tool calls, pass them via on_done
        if finish_reason == "tool_calls" and #accumulated_tool_calls > 0 then
          if on_done then on_done(text, stats, accumulated_tool_calls) end
        else
          if on_done then on_done(text, stats, nil) end
        end
```

(Replace the existing `if on_done then on_done(text, stats) end` at the bottom of `on_exit`.)

- [ ] **Step 2: Add stream_with_tools() agentic loop function**

Add this new function at the end of `lua/neocode/adapters/llama.lua`, before `return M`:

```lua
-- Agentic tool-call loop. Streams a response, executes tool calls, loops until
-- the model produces a final text answer (or max rounds reached).
--
-- opts.tools: array of OpenAI tool schemas
-- opts.on_tool_call: function(tool_call, callback) -- callback(result_text, is_error)
-- opts.on_tool_display: function(tool_call, status) -- update chat buffer display
-- opts.max_rounds: max tool call rounds (default 20)
function M.stream_with_tools(messages, bufnr, on_done, opts)
  opts = opts or {}
  local max_rounds = opts.max_rounds or 20
  local round = 0

  local function do_round()
    round = round + 1
    if round > max_rounds then
      vim.notify("neocode: max tool call rounds reached (" .. max_rounds .. ")", vim.log.levels.WARN)
      if on_done then on_done("", {}, nil) end
      return
    end

    return M.stream(messages, bufnr, function(response_text, stats, tool_calls)
      if not tool_calls or #tool_calls == 0 then
        -- No tool calls: final response
        if on_done then on_done(response_text, stats, nil) end
        return
      end

      -- Model wants to call tools.
      -- Add assistant message with tool_calls to conversation.
      local assistant_msg = {
        role = "assistant",
        content = response_text ~= "" and response_text or nil,
        tool_calls = tool_calls,
      }
      table.insert(messages, assistant_msg)

      -- Process tool calls sequentially
      local pending = #tool_calls
      local completed = 0

      local function process_next(i)
        if i > #tool_calls then
          -- All tools executed, loop back for next round
          -- Remove the empty assistant placeholder that stream() added
          -- (it was the last message before we appended the real assistant_msg)
          vim.schedule(function()
            -- Add new empty assistant for next stream round
            table.insert(messages, { role = "assistant", content = "" })
            do_round()
          end)
          return
        end

        local tc = tool_calls[i]
        if opts.on_tool_display then
          opts.on_tool_display(tc, "running")
        end

        opts.on_tool_call(tc, function(result_text, is_error)
          -- Add tool result message
          table.insert(messages, {
            role = "tool",
            tool_call_id = tc.id,
            content = result_text or "",
          })

          if opts.on_tool_display then
            opts.on_tool_display(tc, is_error and "error" or "done")
          end

          -- Process next tool call
          process_next(i + 1)
        end)
      end

      process_next(1)
    end, { tools = opts.tools })
  end

  return do_round()
end
```

- [ ] **Step 3: Run all existing tests to verify nothing broke**

Run: `cd /Users/johnkarlo/Desktop/NeoCode && nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/neocode/ {minimal_init = 'tests/minimal_init.lua'}"`
Expected: All existing tests PASS (stream signature change is backward-compatible since opts defaults to `{}`)

- [ ] **Step 4: Commit**

```bash
cd /Users/johnkarlo/Desktop/NeoCode
git add lua/neocode/adapters/llama.lua
git commit -m "Add tool calling and agentic loop to Llama adapter"
```

---

### Task 4: Tool Call Rendering in Chat Buffer

**Files:**
- Modify: `lua/neocode/chat_buffer.lua`

- [ ] **Step 1: Write failing test for tool call rendering**

Add to `tests/neocode/chat_buffer_spec.lua`:

```lua
  it("renders tool calls as summary lines", function()
    local cb = require("neocode.chat_buffer")
    local messages = {
      { role = "user", content = "Read my config" },
      {
        role = "assistant",
        content = "Let me check that.",
        tool_calls = {
          { id = "1", type = "function", ["function"] = { name = "filesystem__read_file", arguments = '{"path":"init.lua"}' } },
        },
      },
      { role = "tool", tool_call_id = "1", content = "-- file contents --" },
      { role = "assistant", content = "Here is your config." },
    }
    local lines = cb.render_lines(messages)
    local text = table.concat(lines, "\n")
    assert.is_truthy(text:find("read_file"))
    -- Tool role messages should be hidden
    assert.is_falsy(text:find("file contents"))
  end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/johnkarlo/Desktop/NeoCode && nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/neocode/chat_buffer_spec.lua"`
Expected: FAIL (tool_calls not handled in render_lines)

- [ ] **Step 3: Update render_lines in chat_buffer.lua to handle tool calls and tool results**

In `lua/neocode/chat_buffer.lua`, modify the `render_lines` function. Replace the entire function body:

```lua
function M.render_lines(messages)
  if #messages == 0 then return {} end
  local lines = {}
  for _, msg in ipairs(messages) do
    -- Hide system messages and tool result messages from display
    if msg.role == "system" then goto continue end
    if msg.role == "tool" then goto continue end

    table.insert(lines, "")
    table.insert(lines, ROLE_HEADERS[msg.role] or ("### " .. msg.role))
    table.insert(lines, "")

    -- Render text content
    if type(msg.content) == "string" and msg.content ~= "" then
      for line in (msg.content .. "\n"):gmatch("([^\n]*)\n") do
        table.insert(lines, line)
      end
    elseif type(msg.content) == "table" then
      for _, part in ipairs(msg.content) do
        if part.type == "text" then
          for line in (part.text .. "\n"):gmatch("([^\n]*)\n") do
            table.insert(lines, line)
          end
        elseif part.type == "image_url" then
          table.insert(lines, "*[image]*")
        end
      end
    end

    -- Render tool calls (Claude Code style summary)
    if msg.tool_calls then
      table.insert(lines, "")
      for _, tc in ipairs(msg.tool_calls) do
        local fn = tc["function"] or {}
        local name = fn.name or "unknown"
        -- Extract display name (remove server prefix)
        local display = name:match("^.-__(.+)$") or name
        local args_summary = ""
        local ok_args, args = pcall(vim.fn.json_decode, fn.arguments or "{}")
        if ok_args and type(args) == "table" then
          local parts = {}
          for k, v in pairs(args) do
            local val = type(v) == "string" and v or vim.fn.json_encode(v)
            if #val > 30 then val = val:sub(1, 27) .. "..." end
            table.insert(parts, k .. '="' .. val .. '"')
            if #parts >= 2 then break end
          end
          args_summary = table.concat(parts, " ")
        end

        local status = tc._status or "done"
        local indicator = status == "done" and "[OK]"
          or status == "error" and "[ERR]"
          or status == "denied" and "[denied]"
          or status == "running" and "[...]"
          or ""

        if args_summary ~= "" then
          table.insert(lines, string.format("  > %s %s  %s", display, args_summary, indicator))
        else
          table.insert(lines, string.format("  > %s  %s", display, indicator))
        end
      end
    end

    table.insert(lines, "")
    table.insert(lines, "---")
    ::continue::
  end
  return lines
end
```

- [ ] **Step 4: Run all chat_buffer tests to verify they pass**

Run: `cd /Users/johnkarlo/Desktop/NeoCode && nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/neocode/chat_buffer_spec.lua"`
Expected: All tests PASS (including the new one)

- [ ] **Step 5: Commit**

```bash
cd /Users/johnkarlo/Desktop/NeoCode
git add lua/neocode/chat_buffer.lua tests/neocode/chat_buffer_spec.lua
git commit -m "Add tool call rendering to chat buffer (Claude Code style)"
```

---

### Task 5: Wire MCP Into Session

**Files:**
- Modify: `lua/neocode/session.lua`

This is where everything comes together. The `_open_api_input` function's `do_stream()` is modified to use MCP tools when available.

- [ ] **Step 1: Add MCP require and permission loading to session**

At the top of `lua/neocode/session.lua`, no new requires needed -- we'll lazy-require inside functions.

In the `create_api()` function (around line 202), after `M._persist(config)`, add permission loading:

```lua
  -- Load MCP permissions
  local ok_perms, mcp_perms = pcall(require, "neocode.mcp_permissions")
  if ok_perms then
    mcp_perms.load(config)
  end
```

- [ ] **Step 2: Modify do_stream() to use stream_with_tools when MCP is available**

In `_open_api_input()`, replace the `do_stream()` function body. The current code at line 319-391 calls `llama.stream()`. Replace it with logic that checks for MCP and uses `stream_with_tools()` when tools are available.

Replace the `do_stream` function (lines 319-391) with:

```lua
    local function do_stream()
      local user_msg = llama._build_user_message(text, record.pending_image_b64)
      record.pending_image_b64 = nil
      table.insert(record.messages, user_msg)

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
            label = string.format("%s 🔧 Running tool... %.1fs", spinner_frames[spinner_idx], elapsed)
          elseif spinner_phase == "thinking" then
            label = string.format("%s 💭 Thinking... %.1fs", spinner_frames[spinner_idx], elapsed)
          else
            label = string.format("%s ⚡ Generating... %.1fs", spinner_frames[spinner_idx], elapsed)
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

      -- Check if MCP tools are available
      local ok_mcp, mcp = pcall(require, "neocode.mcp")
      local tools = ok_mcp and mcp.available() and mcp.get_all_tools() or nil

      local function on_complete(response_text, stats, _tool_calls)
        spinner_active = false
        spinner_timer:stop()
        llama._on_phase_change = nil

        -- Find the last real assistant message (not empty placeholders)
        for i = #record.messages, 1, -1 do
          if record.messages[i].role == "assistant" then
            record.messages[i].content = response_text
            break
          end
        end
        record.job_id = nil

        chat_buffer.refresh(record.bufnr, record.messages)

        local history_dir = config.data_dir .. "/llama"
        llama_session_mod.save(history_dir, record.id, record.messages)
      end

      if tools and #tools > 0 then
        -- Use agentic tool-call loop
        local ok_perms, mcp_perms = pcall(require, "neocode.mcp_permissions")

        record.job_id = llama.stream_with_tools(record.messages, record.bufnr, on_complete, {
          tools = tools,
          on_tool_call = function(tool_call, callback)
            local fn = tool_call["function"] or {}
            local server = (fn.name or ""):match("^(.-)__") or "unknown"
            local tool_name = (fn.name or ""):match("__(.+)$") or fn.name or "unknown"

            spinner_phase = "tool"
            phase_start = vim.uv.hrtime()

            local function execute()
              mcp.execute_tool_call(tool_call, function(result, is_error)
                if ok_perms then mcp_perms.consume(server, tool_name) end
                callback(result, is_error)
              end)
            end

            -- Check permissions
            if ok_perms and mcp_perms.is_allowed(server, tool_name) then
              execute()
            elseif ok_perms then
              local ok_args, args = pcall(vim.fn.json_decode, fn.arguments or "{}")
              if not ok_args then args = {} end
              mcp_perms.request(server, tool_name, args, function(allowed)
                if allowed then
                  mcp_perms.save(config)
                  execute()
                else
                  callback("Permission denied by user", true)
                end
              end)
            else
              execute()
            end
          end,
          on_tool_display = function(tool_call, status)
            -- Update tool call status for rendering
            local fn = tool_call["function"] or {}
            for _, msg in ipairs(record.messages) do
              if msg.tool_calls then
                for _, tc in ipairs(msg.tool_calls) do
                  if tc.id == tool_call.id then
                    tc._status = status
                  end
                end
              end
            end
            if record.bufnr and vim.api.nvim_buf_is_valid(record.bufnr) then
              chat_buffer.refresh(record.bufnr, record.messages)
            end
          end,
        })
      else
        -- No MCP tools: use normal streaming
        record.job_id = llama.stream(record.messages, record.bufnr, function(response_text, stats)
          on_complete(response_text, stats, nil)
        end)
      end
    end
```

- [ ] **Step 3: Run all tests to verify nothing broke**

Run: `cd /Users/johnkarlo/Desktop/NeoCode && nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/neocode/ {minimal_init = 'tests/minimal_init.lua'}"`
Expected: All tests PASS

- [ ] **Step 4: Commit**

```bash
cd /Users/johnkarlo/Desktop/NeoCode
git add lua/neocode/session.lua
git commit -m "Wire MCP tool calling into API session flow"
```

---

### Task 6: Update Hints Overlay

**Files:**
- Modify: `lua/neocode/hints.lua`

- [ ] **Step 1: Add MCP status line to hints**

In `lua/neocode/hints.lua`, add a line to the `KEYMAP_LINES` table after the `Q` line:

```lua
  "  [MCP]         Tools auto-detected via mcphub",
```

The full updated `KEYMAP_LINES`:

```lua
local KEYMAP_LINES = {
  "  NeoCode",
  " ──────────────────────────────────────",
  "  <leader>aiC   New session / launcher",
  "  h             Resume session (native picker)",
  "  i             Multi-line input",
  "  <leader>p     Paste image",
  "  <C-c>         Interrupt AI",
  "  Q             Close session",
  "  { / }         Cycle sessions",
  "  <S-p>         Quick session picker",
  "  ?             Toggle this overlay",
  " ──────────────────────────────────────",
  "  MCP tools auto-detected via mcphub",
  " ──────────────────────────────────────",
  "  Press ? or q to dismiss",
}
```

- [ ] **Step 2: Run hints tests**

Run: `cd /Users/johnkarlo/Desktop/NeoCode && nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/neocode/hints_spec.lua"`
Expected: All tests PASS

- [ ] **Step 3: Commit**

```bash
cd /Users/johnkarlo/Desktop/NeoCode
git add lua/neocode/hints.lua
git commit -m "Add MCP info line to hints overlay"
```

---

### Task 7: Integration Test

**Files:** None (manual testing)

- [ ] **Step 1: Run full test suite**

Run: `cd /Users/johnkarlo/Desktop/NeoCode && nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/neocode/ {minimal_init = 'tests/minimal_init.lua'}"`
Expected: All tests PASS

- [ ] **Step 2: Manual test without mcphub**

Open Neovim without mcphub loaded. Start a NeoCode Llama session. Send a message.
Expected: Normal chat works, no errors, no MCP tools injected.

- [ ] **Step 3: Manual test with mcphub**

1. Start llama-server with a tool-calling model
2. Ensure mcphub is running with at least one MCP server (e.g., filesystem)
3. Open NeoCode Llama session
4. Ask: "Read the file README.md in this project"
5. Expected: Model calls `filesystem__read_file`, permission prompt appears, tool executes, result feeds back, model responds with file contents

- [ ] **Step 4: Test permission persistence**

1. Grant "Always allow" for a tool
2. Restart Neovim
3. Start NeoCode Llama session, trigger same tool
4. Expected: No permission prompt (permission loaded from disk)

- [ ] **Step 5: Push all changes**

```bash
cd /Users/johnkarlo/Desktop/NeoCode
git push
```
