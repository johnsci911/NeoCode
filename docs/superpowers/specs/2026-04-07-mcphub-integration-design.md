# NeoCode x mcphub Integration Design

**Date:** 2026-04-07
**Status:** Approved
**Author:** johnsci911

## Goal

Integrate mcphub.nvim into NeoCode's Llama API adapter so local LLMs can call MCP tools, read resources, and use prompts. Uses native tool calling via llama-server's OpenAI-compatible API.

## Architecture

```
User Input -> NeoCode session
  -> Inject available tools/resources/prompts into request
  -> llama-server /v1/chat/completions (with tools param)
  -> Model responds with tool_calls or text
  -> If tool_calls:
      -> Permission check (ask / allow session / always)
      -> hub:call_tool() / hub:access_resource() / hub:get_prompt()
      -> Show brief summary in chat buffer (Claude Code style)
      -> Feed result back to model
      -> Loop until model gives final text answer
  -> Display final response
```

## Components

### 1. `lua/neocode/mcp.lua` -- Core integration module

Bridges NeoCode to mcphub. Responsible for fetching schemas and executing calls.

**Public API:**

```lua
M.available()               -- Returns true if mcphub is installed and hub instance exists
M.get_tools()               -- Returns OpenAI-format tool schemas from all MCP servers
M.get_resources_as_tools()  -- Converts MCP resources into callable tool schemas
M.get_prompts_as_tools()    -- Converts MCP prompts into callable tool schemas
M.get_all_tools()           -- Combined: tools + resources + prompts as tool schemas

M.call_tool(server, tool, args, callback)       -- Execute tool via hub
M.access_resource(server, uri, callback)        -- Read resource via hub
M.use_prompt(server, prompt, args, callback)     -- Get prompt via hub

M.execute_tool_call(tool_call, callback)         -- Route a model tool_call to the right handler
```

**Tool schema format (OpenAI function calling):**

```lua
{
  type = "function",
  function = {
    name = "server_name__tool_name",    -- namespaced
    description = "Tool description",
    parameters = {                       -- from MCP inputSchema
      type = "object",
      properties = { ... },
      required = { ... }
    }
  }
}
```

Resources are exposed as tools:

```lua
{
  type = "function",
  function = {
    name = "mcp_resource__server_name__safe_uri",
    description = "Access resource: <resource_name> from <server>",
    parameters = {
      type = "object",
      properties = {},
      required = {}
    }
  }
}
```

Prompts are exposed as tools:

```lua
{
  type = "function",
  function = {
    name = "mcp_prompt__server_name__prompt_name",
    description = "Prompt template: <prompt description>",
    parameters = {
      type = "object",
      properties = { ... },  -- from prompt arguments
      required = { ... }
    }
  }
}
```

### 2. `lua/neocode/mcp_permissions.lua` -- Permission manager

Controls which tools the model is allowed to execute.

**Permission levels:**

| Level | Scope | Persistence |
|-------|-------|-------------|
| `allowed_once` | Single call | Gone after execution |
| `allowed_session` | Current Neovim session | Cleared on restart |
| `allowed_always` | Permanent | Persisted to `{data_dir}/mcp_permissions.json` |
| `denied` | Single call | Gone after denial |

**Public API:**

```lua
M.check(server, tool)               -- Returns permission level or nil
M.grant(server, tool, level)        -- Set permission
M.request(server, tool, args, cb)   -- Prompt user, call cb(allowed: bool)
M.load(config)                      -- Load persisted permissions
M.save(config)                      -- Save "always" permissions to disk
```

**User prompt (via `vim.ui.select`):**

```
NeoCode: Tool Permission
  server::tool_name
  Args: {"path": "src/main.lua"}

  1. Allow once
  2. Allow for this session
  3. Always allow
  4. Deny
```

### 3. Changes to `lua/neocode/adapters/llama.lua` -- Tool calling support

The `stream()` function is extended with an agentic tool-call loop.

**New parameters:**

```lua
M.stream(messages, bufnr, on_done, opts)
-- opts.tools: array of OpenAI tool schemas (optional)
-- opts.on_tool_call: function(tool_call, callback) called when model wants to use a tool
```

**Agentic loop logic:**

When `tools` are provided in the request:

1. Send request to `/v1/chat/completions` with `tools` array
2. Stream the response as normal
3. When response completes, check if `finish_reason == "tool_calls"` or response contains `tool_calls`
4. If tool calls present:
   - Call `opts.on_tool_call(tool_call, callback)` for each
   - Callback receives the tool result
   - Append assistant message (with tool_calls) and tool result messages to conversation
   - Re-send to model (loop back to step 1)
5. If no tool calls (pure text), call `on_done` as normal

**Tool call message format (OpenAI standard):**

```lua
-- Assistant message with tool calls
{
  role = "assistant",
  content = nil,
  tool_calls = {
    { id = "call_123", type = "function", function = { name = "...", arguments = "..." } }
  }
}

-- Tool result message
{
  role = "tool",
  tool_call_id = "call_123",
  content = "result text"
}
```

### 4. Changes to `lua/neocode/session.lua` -- Wire up MCP

In `_open_api_input` and the streaming flow:

- On session creation, detect if mcphub is available
- Before streaming, fetch tool schemas via `mcp.get_all_tools()`
- Pass tools and `on_tool_call` handler to `llama.stream()`
- The `on_tool_call` handler:
  1. Checks permissions via `mcp_permissions.request()`
  2. On approval, executes via `mcp.execute_tool_call()`
  3. Updates chat buffer with tool summary
  4. Returns result to the agentic loop

### 5. Changes to `lua/neocode/chat_buffer.lua` -- Tool call rendering

New rendering for tool-related messages. Claude Code style -- brief summary, results hidden.

**Tool call display:**

```
### Assistant
Let me check that file for you.

 > Read file src/main.lua  [OK]
 > Search codebase "auth"  [OK]

Based on what I found...
```

**Rendering rules:**

- `role = "assistant"` with `tool_calls`: render text content normally, then each tool call as ` > ToolName args_summary  [pending]`
- `role = "tool"`: do not render (results are hidden, fed back to model only)
- Status indicators: `[OK]` for success, `[ERR]` for error, `[denied]` if user denied permission

## Error Handling

- **mcphub not installed**: NeoCode works normally without MCP, no tools injected
- **mcphub not ready** (servers starting): retry once, then proceed without tools
- **Tool execution fails**: show `[ERR]` in chat, feed error to model so it can respond
- **Model generates invalid tool call**: feed error back as tool result, let model retry
- **Permission denied**: feed "permission denied" as tool result, model proceeds without that tool
- **Agentic loop limit**: max 20 tool-call rounds per message to prevent infinite loops

## File Summary

| File | Action | Purpose |
|------|--------|---------|
| `lua/neocode/mcp.lua` | New | Core mcphub bridge |
| `lua/neocode/mcp_permissions.lua` | New | Permission manager |
| `lua/neocode/adapters/llama.lua` | Modify | Add tool calling + agentic loop |
| `lua/neocode/session.lua` | Modify | Wire MCP into API sessions |
| `lua/neocode/chat_buffer.lua` | Modify | Render tool calls Claude Code style |
| `lua/neocode/hints.lua` | Modify | Add MCP-related hints if applicable |

## Testing Strategy

- Unit tests for `mcp_permissions.lua` (grant/check/persist)
- Unit tests for tool schema formatting in `mcp.lua`
- Integration test: mock hub instance, verify tool call loop
- Manual testing with llama-server + mcphub servers

## Dependencies

- mcphub.nvim (optional -- NeoCode works without it)
- llama-server with a model that supports tool calling (e.g., Qwen3.5-9B)

## Future Considerations

- Streaming tool calls (model streams text, then emits tool call mid-stream)
- Tool call history in session persistence
- Per-server permission groups (e.g., "allow all filesystem tools")
