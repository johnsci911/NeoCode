-- lua/neocode/adapters/llama.lua
local chat_buffer = require("neocode.chat_buffer")

local M = {}

M.name = "llama"
M.type = "api"       -- signals NeoCode this is not a CLI adapter
M.session_store = true

M.defaults = {
  base_url = "http://localhost:8080",
  model = nil, -- auto-detect from server
}

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.defaults, opts or {})
  M._user_configured_model = opts and opts.model ~= nil
end

-- Query the running server for its loaded model name.
-- Returns the model id string, or nil on failure.
function M._detect_model(base_url)
  local result = vim.fn.system({ "curl", "--silent", "--max-time", "2", base_url .. "/v1/models" })
  local ok, data = pcall(vim.fn.json_decode, result)
  if ok and data and data.data and data.data[1] then
    return data.data[1].id
  end
  return nil
end

-- Build the messages payload, including any pending image.
function M._build_user_message(text, image_base64)
  if image_base64 then
    return {
      role = "user",
      content = {
        { type = "text", text = text },
        { type = "image_url", image_url = { url = "data:image/png;base64," .. image_base64 } },
      },
    }
  end
  return { role = "user", content = text }
end

-- Send messages to llama-server and stream the response into the buffer.
-- on_done receives (response_text, stats) where stats = { tokens, elapsed, tps, model, thinking_time }
function M.stream(messages, bufnr, on_done, opts)
  local cfg = M.config or M.defaults

  -- Auto-detect model from server unless user explicitly configured one
  if not M._user_configured_model then
    cfg.model = M._detect_model(cfg.base_url) or cfg.model or "unknown"
  end

  local url = cfg.base_url .. "/v1/chat/completions"

  -- Filter out empty assistant messages to avoid conflicts with thinking mode
  local filtered = {}
  local has_system = false
  for _, msg in ipairs(messages) do
    if msg.role == "system" then has_system = true end
    if not (msg.role == "assistant" and (msg.content == nil or msg.content == "")) then
      table.insert(filtered, msg)
    end
  end

  -- Trim conversation to fit context: keep system + last N messages
  local max_messages = cfg.max_messages or 30
  if #filtered > max_messages then
    local trimmed = {}
    -- Keep system messages
    for _, msg in ipairs(filtered) do
      if msg.role == "system" then
        table.insert(trimmed, msg)
      end
    end
    -- Keep the last (max_messages - #system) non-system messages
    local non_system = {}
    for _, msg in ipairs(filtered) do
      if msg.role ~= "system" then
        table.insert(non_system, msg)
      end
    end
    local keep = max_messages - #trimmed
    local start = math.max(1, #non_system - keep + 1)
    for i = start, #non_system do
      table.insert(trimmed, non_system[i])
    end
    filtered = trimmed
  end

  -- Add system prompt if none exists to reduce hallucination
  if not has_system and cfg.system_prompt ~= false then
    local default_prompt = "You are a helpful assistant. Be concise and accurate. Do not repeat yourself. Do not output thinking tags like <think> or </think>."
    -- When tools are available, instruct the model to actually call them
    if opts and opts.tools and #opts.tools > 0 then
      default_prompt = default_prompt
        .. "\n\nYou have access to tools. When the user asks you to do something that requires reading files, searching, listing directories, or any task a tool can handle, you MUST call the appropriate tool using the function calling format. Do NOT describe what you would do -- actually call the tool. Always use tools when they can help answer the user's question."
    end
    table.insert(filtered, 1, {
      role = "system",
      content = cfg.system_prompt or default_prompt,
    })
  end

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

  -- Disable thinking mode when tools are active (faster tool calling)
  if cfg.thinking == false or (opts.tools and #opts.tools > 0) then
    request_body.temperature = request_body.temperature or 0.7
    -- Qwen3 hint: /no_think can be appended, but chat_template control is better
    -- Some models support this field directly
    request_body.enable_thinking = false
  end

  local payload = vim.fn.json_encode(request_body)

  local full_response = {}
  local partial_line = ""
  local repetition_window = 50
  local repetition_threshold = 3

  -- Stats tracking
  local start_time = vim.uv.hrtime()
  local first_token_time = nil
  local thinking = true  -- assume thinking until first content token
  local token_count = 0
  local usage_data = nil  -- populated from final chunk
  local accumulated_tool_calls = {}
  local finish_reason = nil
  local in_think_block = false

  -- Callback to notify phase changes (thinking → generating)
  local on_phase_change = M._on_phase_change

  local job_id = vim.fn.jobstart({
    "curl", "--silent", "--no-buffer",
    "-X", "POST", url,
    "-H", "Content-Type: application/json",
    "-d", payload,
  }, {
    on_stdout = function(_, data, _)
      for _, raw in ipairs(data) do
        local line = partial_line .. raw
        partial_line = ""

        if line == "" then
          goto continue
        end

        local json_str = line:match("^data:%s*(.+)")
        if not json_str or json_str == "[DONE]" then
          if not line:match("^data:") and line ~= "" then
            partial_line = line
          end
          goto continue
        end

        local ok, chunk = pcall(vim.fn.json_decode, json_str)
        if ok and chunk then
          -- Capture usage data (sent in final chunk)
          if chunk.usage then
            usage_data = chunk.usage
          end
        end
        if ok and chunk and chunk.choices and chunk.choices[1] then
          local delta = chunk.choices[1].delta
          local content = delta and delta.content
          if content and type(content) == "string" and content ~= "" then
            -- Handle think tags: show thinking as blockquote
            if content:match("<think>") then
              in_think_block = true
              content = content:gsub("<think>", "")
              -- Add thinking header
              vim.schedule(function()
                if not vim.api.nvim_buf_is_valid(bufnr) then return end
                chat_buffer.append_token(bufnr, "*thinking...*\n> ")
              end)
              if content == "" then goto continue end
            end
            if content:match("</think>") then
              in_think_block = false
              content = content:gsub("</think>", "")
              -- End thinking block, transition to generating
              vim.schedule(function()
                if not vim.api.nvim_buf_is_valid(bufnr) then return end
                chat_buffer.append_token(bufnr, "\n\n")
              end)
              if not thinking then goto continue end
            end
            -- Prefix newlines with > inside think blocks
            if in_think_block then
              content = content:gsub("\n", "\n> ")
            end

            -- Transition from thinking to generating on first content outside think block
            if thinking and not in_think_block and content ~= "" then
              thinking = false
              first_token_time = vim.uv.hrtime()
              if on_phase_change then
                vim.schedule(function() on_phase_change("generating") end)
              end
            end

            token_count = token_count + 1
            table.insert(full_response, content)

            -- Repetition detection
            if #full_response >= repetition_window then
              local recent = table.concat(full_response, "", #full_response - repetition_window + 1)
              local len = #recent
              for plen = 10, math.floor(len / repetition_threshold) do
                local pattern = recent:sub(1, plen)
                local count = 0
                for i = 1, len - plen + 1, plen do
                  if recent:sub(i, i + plen - 1) == pattern then
                    count = count + 1
                  else
                    break
                  end
                end
                if count >= repetition_threshold then
                  vim.schedule(function()
                    pcall(vim.fn.jobstop, job_id)
                    if not vim.api.nvim_buf_is_valid(bufnr) then return end
                    vim.bo[bufnr].modifiable = true
                    local lc = vim.api.nvim_buf_line_count(bufnr)
                    vim.api.nvim_buf_set_lines(bufnr, lc, lc, false,
                      { "", "--- [stopped: repetition detected] ---" })
                    vim.bo[bufnr].modifiable = false
                    vim.notify("neocode: stopped — repetitive output detected", vim.log.levels.WARN)
                  end)
                  return
                end
              end
            end

            vim.schedule(function()
              if not vim.api.nvim_buf_is_valid(bufnr) then return end
              -- Clear spinner line on first token
              if #full_response == 1 then
                local total = vim.api.nvim_buf_line_count(bufnr)
                local last = vim.api.nvim_buf_get_lines(bufnr, total - 1, total, false)[1] or ""
                if last:match("Thinking") or last:match("Generating") or last:match("Processing") then
                  vim.bo[bufnr].modifiable = true
                  vim.api.nvim_buf_set_lines(bufnr, total - 1, total, false, { "" })
                  vim.bo[bufnr].modifiable = false
                end
              end
              chat_buffer.append_token(bufnr, content)
              for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
                local lc = vim.api.nvim_buf_line_count(bufnr)
                vim.api.nvim_win_set_cursor(win, { lc, 0 })
              end
            end)
          end

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
        else
          partial_line = line
        end

        ::continue::
      end
    end,
    on_exit = function(_, exit_code, _)
      vim.schedule(function()
        local text = table.concat(full_response)
        -- Strip think block content from stored response (keep display clean for history)
        text = text:gsub("<think>.-</think>", "")
        local elapsed_ns = vim.uv.hrtime() - start_time
        local elapsed_s = elapsed_ns / 1e9
        local thinking_s = first_token_time and ((first_token_time - start_time) / 1e9) or elapsed_s
        local gen_s = elapsed_s - thinking_s
        local tps = gen_s > 0 and (token_count / gen_s) or 0

        -- Context usage from server
        local ctx_max = cfg.context_size or 32768
        local prompt_tokens = usage_data and usage_data.prompt_tokens or 0
        local completion_tokens = usage_data and usage_data.completion_tokens or token_count
        local total_tokens = prompt_tokens + completion_tokens
        local ctx_pct = ctx_max > 0 and math.floor((total_tokens / ctx_max) * 100) or 0

        local stats = {
          model = cfg.model,
          tokens = token_count,
          elapsed = elapsed_s,
          thinking_time = thinking_s,
          tps = tps,
          prompt_tokens = prompt_tokens,
          completion_tokens = completion_tokens,
          total_tokens = total_tokens,
          context_size = ctx_max,
          context_pct = ctx_pct,
        }

        -- Build stats line (buffer may have been closed)
        if not vim.api.nvim_buf_is_valid(bufnr) then
          if on_done then on_done(text, stats, nil) end
          return
        end
        vim.bo[bufnr].modifiable = true
        local lc = vim.api.nvim_buf_line_count(bufnr)
        local parts = { string.format("  %s", cfg.model) }

        -- Context usage
        if total_tokens > 0 then
          table.insert(parts, string.format("ctx: %d/%d (%d%%)", total_tokens, ctx_max, ctx_pct))
        end

        table.insert(parts, string.format(" %d tokens", completion_tokens))

        if thinking_s > 0.5 then
          table.insert(parts, string.format("💭 %.1fs", thinking_s))
        end

        table.insert(parts, string.format("⏱ %.1fs", elapsed_s))
        table.insert(parts, string.format("⚡ %.1f t/s", tps))

        local stats_line = table.concat(parts, " │ ")
        vim.api.nvim_buf_set_lines(bufnr, lc, lc, false, { "", stats_line, "", "---" })
        vim.bo[bufnr].modifiable = false

        if finish_reason == "tool_calls" and #accumulated_tool_calls > 0 then
          if on_done then on_done(text, stats, accumulated_tool_calls) end
        else
          if on_done then on_done(text, stats, nil) end
        end
      end)
    end,
  })

  return job_id
end

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
      local function process_next(i)
        if i > #tool_calls then
          -- All tools executed, loop back for next round
          vim.schedule(function()
            -- Notify session to restart spinner
            if opts.on_round_start then
              opts.on_round_start(round + 1)
            end
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

return M
