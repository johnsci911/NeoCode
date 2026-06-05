-- lua/neocode/chat_buffer.lua
local M = {}

local NS = vim.api.nvim_create_namespace("neocode_chat_blocks")

local ROLE_HEADERS = {
  user = "You",
  assistant = "Assistant",
  system = "System",
}

local DEFAULT_RULE_WIDTH = 78

local function rule_width(opts)
  local width = tonumber(opts and opts.width) or DEFAULT_RULE_WIDTH
  return math.max(20, math.floor(width))
end

local function separator(label, top, opts)
  local width = rule_width(opts)
  if not top then
    return string.rep("─", width)
  end

  local title = " " .. label .. " "
  local used = vim.fn.strdisplaywidth(title)
  local left = string.rep("─", 2)
  local right = string.rep("─", math.max(1, width - used - vim.fn.strdisplaywidth(left)))
  return left .. title .. right
end

-- Detect unified-diff content in a tool result preview and strip the verbose
-- header lines (Index:/===/---/+++) so we render just the hunks. Some edit
-- tools return diffs, and we want them shown inline
-- with ```diff ``` fences so render-markdown.nvim highlights the +/- lines
-- instead of burying them under a 2-space indent.
--
-- Returns (is_diff, body) — body is the content to render (without the
-- original ```diff fence if present, and with header lines stripped).
local function normalize_diff_preview(preview)
  -- Strip an existing ```diff``` or ```patch``` fence if a tool added one
  local stripped = preview
  local had_fence = preview:match("^```diff") or preview:match("^```patch")
  if had_fence then
    stripped = preview:gsub("^```%w*\r?\n", ""):gsub("\n```%s*$", "")
  end

  -- Detect unified diff markers
  local is_diff = had_fence
    or stripped:match("^diff %-%-git")
    or (stripped:match("%-%-%- ") and stripped:match("%+%+%+ ") and stripped:match("@@ "))

  if not is_diff then
    return false, preview
  end

  -- Keep everything from the first @@ hunk onward; drop Index/===/---/+++
  -- noise that duplicates the file path already shown in the tool header.
  local hunks = {}
  local in_hunk = false
  for line in (stripped .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^@@") then in_hunk = true end
    if in_hunk then table.insert(hunks, line) end
  end

  if #hunks == 0 then
    return true, stripped  -- diff detected but no hunks parsed — show as-is
  end
  return true, table.concat(hunks, "\n")
end

local function append_block(lines, blocks, label, body, opts)
  if #body == 0 then return end

  if #lines > 0 then table.insert(lines, "") end
  local top_line = #lines + 1
  table.insert(lines, separator(label, true, opts))
  local content_start = #lines + 1
  for _, raw_line in ipairs(body) do
    table.insert(lines, raw_line or "")
  end
  local content_end = #lines
  table.insert(lines, separator(label, false, opts))
  table.insert(blocks, {
    label = label,
    top = top_line,
    content_start = content_start,
    content_end = content_end,
    bottom = #lines,
  })
end

-- Convert a messages array into boxed markdown text. The actual buffer lines
-- inside each box are left as plain markdown so fenced code blocks can still be
-- highlighted by Neovim/Tree-sitter/render-markdown. Side borders are drawn as
-- virtual text in refresh().
function M.render_lines(messages, opts)
  if #messages == 0 then return {} end
  local lines = {}
  local blocks = {}
  local prev_visible_role = nil

  for _, msg in ipairs(messages) do
    -- Hide system messages and tool result messages from display
    if msg.role == "system" then goto continue end
    if msg.role == "tool" then goto continue end

    local has_text = (type(msg.content) == "string" and msg.content ~= "")
      or (type(msg.content) == "table" and #msg.content > 0)
    local has_tools = msg.tool_calls and #msg.tool_calls > 0
    local has_stats = msg._stats ~= nil

    -- Group consecutive assistant messages: only show header for the first one
    local show_header = true
    if msg.role == "assistant" and prev_visible_role == "assistant" then
      show_header = false
    end
    -- Tool-only messages (no text, no stats) never get a header
    if not has_text and not has_stats and has_tools then
      show_header = false
    end

    local body = {}

    prev_visible_role = msg.role

    -- Render text content (with thinking blocks as blockquotes)
    if type(msg.content) == "string" and msg.content ~= "" then
      local content = msg.content
      -- Strip tool call artifacts (model sometimes outputs these as text)
      content = content:gsub("</?tool_call>", "")
      content = content:gsub('%{"function":%s*".-"%s*,%s*"arguments":%s*%b{}%s*%}', "")
      -- Render <think> blocks as blockquotes
      content = content:gsub("<think>", "\n*thinking...*\n")
      content = content:gsub("</think>", "\n\n")
      for line in (content .. "\n"):gmatch("([^\n]*)\n") do
        -- Indent lines between thinking markers as blockquotes
        table.insert(body, line)
      end
    elseif type(msg.content) == "table" then
      for _, part in ipairs(msg.content) do
        if part.type == "text" then
          for line in (part.text .. "\n"):gmatch("([^\n]*)\n") do
            table.insert(body, line)
          end
        elseif part.type == "image_url" then
          table.insert(body, "*[image]*")
        end
      end
    end

    -- Render tool calls (Claude Code style with result preview)
    if msg.tool_calls then
      for _, tc in ipairs(msg.tool_calls) do
        local fn = tc["function"] or {}
        local name = fn.name or "unknown"
        local display = name:match("^.-__(.+)$") or name

        -- Detect tool action icon from name
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
        end

        -- Build args for header
        local args_summary = ""
        local ok_args, args = pcall(vim.fn.json_decode, fn.arguments or "{}")
        if ok_args and type(args) == "table" then
          local primary = args.path or args.uri or args.query or args.command or args.file or args.name
          if primary then
            args_summary = primary
          end
        end

        local status = tc._status or "done"
        local status_icon = status == "done" and " ✓"
          or status == "error" and " ✗"
          or status == "denied" and " ⊘"
          or status == "running" and " ..."
          or ""

        -- Tool header line (like Claude Code)
        if #body > 0 then table.insert(body, "") end
        if args_summary ~= "" then
          table.insert(body, string.format("%s **%s**(%s)%s", icon, display, args_summary, status_icon))
        else
          table.insert(body, string.format("%s **%s**%s", icon, display, status_icon))
        end

        -- Result preview (first few lines of output).
        -- For unified diffs, render up to 20 lines inside a ```diff fence
        -- (un-indented) so render-markdown.nvim highlights +/- lines; for
        -- plain output, keep the 6-line / 2-space-indent layout.
        if tc._result_preview and tc._result_preview ~= "" and tc._result_preview ~= "(empty result)" then
          local is_diff, preview_body = normalize_diff_preview(tc._result_preview)
          local max_preview = is_diff and 20 or 6
          local indent = is_diff and "" or "  "

          local preview_lines = {}
          local total_lines = 0
          for pline in (preview_body .. "\n"):gmatch("([^\n]*)\n") do
            total_lines = total_lines + 1
            if #preview_lines < max_preview then
              table.insert(preview_lines, indent .. pline)
            end
          end

          if is_diff then
            table.insert(body, "```diff")
            for _, pl in ipairs(preview_lines) do
              table.insert(body, pl)
            end
            table.insert(body, "```")
          else
            for _, pl in ipairs(preview_lines) do
              table.insert(body, pl)
            end
          end

          if total_lines > max_preview then
            table.insert(body, string.format("%s*...%d more lines*", indent, total_lines - max_preview))
          end
        elseif status == "error" and tc._result_preview then
          table.insert(body, "  " .. tc._result_preview)
        end
      end
    end

    -- Show stats/done indicator for completed assistant messages
    if msg.role == "assistant" and msg._stats then
      local s = msg._stats
      if #body > 0 then table.insert(body, "") end
      local parts = {}
      if s.model then table.insert(parts, s.model) end
      local tokens = s.completion_tokens or s.tokens or 0
      if tokens > 0 then
        table.insert(parts, string.format("%d tokens", tokens))
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
      if s.prompt_tokens and s.prompt_tokens > 0 then
        local ctx_max = s.context_size or 32768
        local used = s.prompt_tokens + (s.completion_tokens or 0)
        local pct = math.floor((used / ctx_max) * 100)
        table.insert(parts, string.format("ctx: %d/%d (%d%%)", used, ctx_max, pct))
      end
      if #parts > 0 then
        table.insert(body, "✅ " .. table.concat(parts, " · "))
      else
        table.insert(body, "✅ Done")
      end
    end

    local label = ROLE_HEADERS[msg.role] or msg.role
    if not show_header and msg.role == "assistant" then
      label = "Assistant"
    end
    if #body > 0 then
      append_block(lines, blocks, label, body, opts)
    end
    ::continue::
  end
  if opts and opts.metadata then return lines, blocks end
  return lines
end

function M._apply_block_decorations(bufnr, blocks)
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  for _, block in ipairs(blocks or {}) do
    if block.top then
      vim.api.nvim_buf_add_highlight(bufnr, NS, "NeoCodeBlockBorder", block.top - 1, 0, -1)
    end
    if block.bottom then
      vim.api.nvim_buf_add_highlight(bufnr, NS, "NeoCodeBlockBorder", block.bottom - 1, 0, -1)
    end
  end
end

local function buffer_rule_width(bufnr)
  local width = vim.o.columns
  local windows = vim.fn.win_findbuf(bufnr)
  if #windows > 0 then
    width = 0
    for _, win in ipairs(windows) do
      if vim.api.nvim_win_is_valid(win) then
        width = math.max(width, vim.api.nvim_win_get_width(win))
      end
    end
  end
  return math.max(20, width - 4)
end

-- Create or update a buffer with rendered messages.
function M.refresh(bufnr, messages)
  local lines, blocks = M.render_lines(messages, { metadata = true, width = buffer_rule_width(bufnr) })
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].filetype = "markdown"
  M._apply_block_decorations(bufnr, blocks)
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
