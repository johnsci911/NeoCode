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
