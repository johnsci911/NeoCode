-- lua/neocode/chat_buffer.lua
local M = {}

local ROLE_HEADERS = {
  user = "### You",
  assistant = "### Assistant",
  system = "### System",
}

-- Convert a messages array into lines of markdown text.
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

    -- Render tool calls (Claude Code style)
    if msg.tool_calls then
      table.insert(lines, "")
      for _, tc in ipairs(msg.tool_calls) do
        local fn = tc["function"] or {}
        local name = fn.name or "unknown"
        local display = name:match("^.-__(.+)$") or name

        -- Detect tool action mode from name
        local icon = "🔧"
        local lower = display:lower()
        if lower:match("read") or lower:match("get") or lower:match("list") or lower:match("search") or lower:match("find") then
          icon = "📖"
        elseif lower:match("write") or lower:match("edit") or lower:match("create") or lower:match("update") or lower:match("patch") then
          icon = "✏️"
        elseif lower:match("delete") or lower:match("remove") then
          icon = "🗑️"
        elseif lower:match("run") or lower:match("exec") or lower:match("shell") or lower:match("command") then
          icon = "⚡"
        elseif name:match("^mcp_resource__") then
          icon = "📄"
        elseif name:match("^mcp_prompt__") then
          icon = "📋"
        end

        -- Build args summary
        local args_summary = ""
        local ok_args, args = pcall(vim.fn.json_decode, fn.arguments or "{}")
        if ok_args and type(args) == "table" then
          -- Show the most relevant arg value directly
          local primary = args.path or args.uri or args.query or args.command or args.file or args.name
          if primary then
            if #primary > 50 then primary = primary:sub(1, 47) .. "..." end
            args_summary = primary
          else
            local parts = {}
            for k, v in pairs(args) do
              local val = type(v) == "string" and v or vim.fn.json_encode(v)
              if #val > 30 then val = val:sub(1, 27) .. "..." end
              table.insert(parts, k .. "=" .. val)
              if #parts >= 2 then break end
            end
            args_summary = table.concat(parts, " ")
          end
        end

        local status = tc._status or "done"
        local status_icon = status == "done" and "  ✓"
          or status == "error" and "  ✗"
          or status == "denied" and "  ⊘"
          or status == "running" and "  ..."
          or ""

        if args_summary ~= "" then
          table.insert(lines, string.format("  %s %s %s%s", icon, display, args_summary, status_icon))
        else
          table.insert(lines, string.format("  %s %s%s", icon, display, status_icon))
        end
      end
    end

    -- Show stats/done indicator for completed assistant messages
    if msg.role == "assistant" and msg._stats then
      local s = msg._stats
      table.insert(lines, "")
      local parts = {}
      if s.model then table.insert(parts, s.model) end
      if s.completion_tokens and s.completion_tokens > 0 then
        table.insert(parts, string.format("%d tokens", s.completion_tokens))
      end
      if s.thinking_time and s.thinking_time > 0.5 then
        table.insert(parts, string.format("💭 %.1fs", s.thinking_time))
      end
      if s.elapsed and s.elapsed > 0 then
        table.insert(parts, string.format("%.1fs", s.elapsed))
      end
      if s.tps and s.tps > 0 then
        table.insert(parts, string.format("%.1f t/s", s.tps))
      end
      if #parts > 0 then
        table.insert(lines, "✅ " .. table.concat(parts, " · "))
      else
        table.insert(lines, "✅ Done")
      end
    end

    table.insert(lines, "")
    table.insert(lines, "---")
    ::continue::
  end
  return lines
end

-- Create or update a buffer with rendered messages.
function M.refresh(bufnr, messages)
  local lines = M.render_lines(messages)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].filetype = "markdown"
  return bufnr
end

-- Create a new chat buffer.
function M.create(messages)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  M.refresh(buf, messages or {})
  return buf
end

-- Append a streaming token to the last line of the buffer.
function M.append_token(bufnr, token)
  vim.bo[bufnr].modifiable = true
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local last_line = vim.api.nvim_buf_get_lines(bufnr, line_count - 1, line_count, false)[1] or ""

  local parts = vim.split(token, "\n", { plain = true })

  if #parts == 1 then
    vim.api.nvim_buf_set_lines(bufnr, line_count - 1, line_count, false, { last_line .. parts[1] })
  else
    local new_lines = { last_line .. parts[1] }
    for i = 2, #parts do
      table.insert(new_lines, parts[i])
    end
    vim.api.nvim_buf_set_lines(bufnr, line_count - 1, line_count, false, new_lines)
  end
  vim.bo[bufnr].modifiable = false
end

return M
