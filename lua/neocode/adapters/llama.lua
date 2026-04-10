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
    local detected = M._detect_model(cfg.base_url)
    if detected then
      cfg.model = detected
    elseif not cfg.model then
      cfg.model = "unknown"
      vim.notify("neocode: cannot reach llama-server at " .. cfg.base_url .. " — is it running?", vim.log.levels.WARN)
    end
  end

  local url = cfg.base_url .. "/v1/chat/completions"

  -- Filter messages: strip think blocks from history, remove empty assistants
  local filtered = {}
  local has_system = false
  for _, msg in ipairs(messages) do
    if msg.role == "system" then has_system = true end
    if msg.role == "assistant" and (msg.content == nil or msg.content == "") then
      goto skip
    end
    -- Strip <think> blocks from assistant messages to save context
    if msg.role == "assistant" and type(msg.content) == "string" and msg.content:match("<think>") then
      local clean = msg.content:gsub("<think>.-</think>", ""):gsub("^%s+", "")
      if clean == "" then goto skip end -- skip if only thinking, no actual content
      table.insert(filtered, vim.tbl_extend("force", msg, { content = clean }))
    else
      table.insert(filtered, msg)
    end
    ::skip::
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
    -- When tools are available, add project context and tool instructions
    if opts and opts.tools and #opts.tools > 0 then
      local cwd = opts.cwd or require("neocode.context").find_project_root()
      local is_git = vim.fn.isdirectory(cwd .. "/.git") == 1
      local home = vim.fn.expand("~")
      local project_info = string.format("\n\nSystem: macOS, home directory: %s\nCurrent working directory: %s", home, cwd)
      if is_git then
        local branch = vim.fn.system("git -C " .. vim.fn.shellescape(cwd) .. " branch --show-current 2>/dev/null"):gsub("%s+$", "")
        project_info = project_info .. string.format("\nThis is a git repository (branch: %s)", branch)
      end
      -- List top-level files for context
      local ls = vim.fn.glob(cwd .. "/*", false, true)
      if #ls > 0 then
        local names = {}
        for _, path in ipairs(ls) do
          local name = vim.fn.fnamemodify(path, ":t")
          if vim.fn.isdirectory(path) == 1 then name = name .. "/" end
          table.insert(names, name)
          if #names >= 15 then break end
        end
        project_info = project_info .. "\nTop-level files: " .. table.concat(names, ", ")
      end

      -- List available tools explicitly in the prompt (some models ignore the tools API param)
      local tool_names = {}
      for _, t in ipairs(opts.tools) do
        local fn = t["function"] or t
        if fn.name then
          table.insert(tool_names, fn.name .. ": " .. (fn.description or ""):sub(1, 80))
        end
        if #tool_names >= 10 then break end
      end
      local tools_list = ""
      if #tool_names > 0 then
        tools_list = "\n\nAvailable tools:\n- " .. table.concat(tool_names, "\n- ")
      end

      default_prompt = default_prompt .. project_info .. tools_list
        .. "\n\nIMPORTANT: You have direct access to the user's filesystem and project files through the tools listed above. You CAN read files, list directories, search code, and execute commands. Do NOT tell the user you cannot access their files. Do NOT ask users to paste code or share URLs. Instead, USE the tools to read their files directly."
        .. "\nWhen the user asks about their code or project, IMMEDIATELY call the appropriate tool (like read_file or list_directory) using the function calling format."
        .. "\nAlways use absolute paths based on the working directory: " .. cwd

      -- Inject project context files (.neocode.md, CLAUDE.md, README.md, etc.)
      local ok_ctx, context = pcall(require, "neocode.context")
      if ok_ctx then
        local project_context = context.gather(cwd)
        if project_context then
          default_prompt = default_prompt .. "\n\n" .. project_context
        end
      end
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
    repeat_penalty = cfg.repeat_penalty or 1.1,
    max_tokens = cfg.max_tokens or 16384,
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
              -- Clear spinner line and add thinking header
              vim.schedule(function()
                if not vim.api.nvim_buf_is_valid(bufnr) then return end
                vim.bo[bufnr].modifiable = true
                local total = vim.api.nvim_buf_line_count(bufnr)
                local last = vim.api.nvim_buf_get_lines(bufnr, total - 1, total, false)[1] or ""
                if last:match("Thinking") or last:match("Generating") then
                  vim.api.nvim_buf_set_lines(bufnr, total - 1, total, false,
                    { "*thinking...*", "", "> " })
                else
                  vim.api.nvim_buf_set_lines(bufnr, total, total, false,
                    { "*thinking...*", "", "> " })
                end
                vim.bo[bufnr].modifiable = false
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

            -- Filter out <tool_call> XML tags (model sometimes outputs these as text
            -- instead of using proper structured tool_calls)
            if content:match("</?tool_call>") then
              content = content:gsub("</?tool_call>", "")
              if content:match("^%s*$") then goto continue end
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

            -- Update live stats for spinner display
            local now = vim.uv.hrtime()
            local gen_elapsed = first_token_time and ((now - first_token_time) / 1e9) or 0
            M._live_stats = {
              token_count = token_count,
              tps = gen_elapsed > 0 and (token_count / gen_elapsed) or 0,
              usage = usage_data,
              context_size = cfg.context_size or 32768,
            }

            -- Degenerate output detection: check for gibberish (replaces old repetition detector
            -- which false-triggered on ASCII art, tables, and markdown formatting)
            if token_count > 200 and token_count % 100 == 0 then
              local window = math.min(100, #full_response)
              local recent = table.concat(full_response, "", #full_response - window + 1)
              -- Count meaningful chars (letters, digits, markdown-safe punctuation)
              local meaningful = recent:gsub("[^%w%s%.%,%(%)%-%|%:%;%!%?%#%*%/]", "")
              local ratio = #meaningful / math.max(1, #recent)
              if ratio < 0.3 then
                vim.schedule(function()
                  pcall(vim.fn.jobstop, job_id)
                  if not vim.api.nvim_buf_is_valid(bufnr) then return end
                  vim.bo[bufnr].modifiable = true
                  local lc = vim.api.nvim_buf_line_count(bufnr)
                  vim.api.nvim_buf_set_lines(bufnr, lc, lc, false,
                    { "", "--- [stopped: degenerate output] ---" })
                  vim.bo[bufnr].modifiable = false
                  vim.notify("neocode: stopped — output quality degraded", vim.log.levels.WARN)
                end)
                return
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
        M._live_stats = nil

        -- Detect connection failure
        if exit_code ~= 0 and token_count == 0 then
          local error_msg = "neocode: connection to llama-server failed"
          if exit_code == 7 then
            error_msg = "neocode: llama-server not running (connection refused)"
          elseif exit_code == 28 then
            error_msg = "neocode: llama-server timed out"
          elseif exit_code == 52 then
            error_msg = "neocode: llama-server returned empty response"
          end
          vim.notify(error_msg .. " (exit code: " .. exit_code .. ")", vim.log.levels.ERROR)

          if vim.api.nvim_buf_is_valid(bufnr) then
            vim.bo[bufnr].modifiable = true
            local lc = vim.api.nvim_buf_line_count(bufnr)
            vim.api.nvim_buf_set_lines(bufnr, lc - 1, lc, false, {
              "⚠️ " .. error_msg,
              "Make sure llama-server is running at: " .. cfg.base_url,
            })
            vim.bo[bufnr].modifiable = false
          end

          if on_done then on_done("", {}, nil) end
          return
        end

        local text = table.concat(full_response)
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

        if finish_reason == "tool_calls" and #accumulated_tool_calls > 0 then
          if on_done then on_done(text, stats, accumulated_tool_calls) end
        else
          -- Fallback: parse <tool_call> XML tags from text (some models use this format)
          local parsed_tool_calls = {}
          for tc_content in text:gmatch("<tool_call>(.-)<%/tool_call>") do
            local tc_json = tc_content:gsub("^%s+", ""):gsub("%s+$", "")
            local tc_ok, tc_data = pcall(vim.fn.json_decode, tc_json)
            if tc_ok and type(tc_data) == "table" then
              local tc_name = tc_data.name or tc_data[1]
              local tc_args = tc_data.arguments or tc_data.parameters or {}
              if tc_name then
                table.insert(parsed_tool_calls, {
                  id = "text_call_" .. #parsed_tool_calls + 1,
                  type = "function",
                  ["function"] = {
                    name = tc_name,
                    arguments = vim.fn.json_encode(tc_args),
                  },
                })
              end
            end
          end

          -- Also detect bare JSON tool calls: {"function": "name", "arguments": {...}}
          if #parsed_tool_calls == 0 then
            for json_tc in text:gmatch('%{"function":%s*".-"%s*,%s*"arguments":%s*%b{}%s*%}') do
              local tc_ok, tc_data = pcall(vim.fn.json_decode, json_tc)
              if tc_ok and type(tc_data) == "table" then
                local tc_name = tc_data["function"] or tc_data.name
                local tc_args = tc_data.arguments or {}
                if tc_name then
                  table.insert(parsed_tool_calls, {
                    id = "json_call_" .. #parsed_tool_calls + 1,
                    type = "function",
                    ["function"] = {
                      name = tc_name,
                      arguments = type(tc_args) == "string" and tc_args or vim.fn.json_encode(tc_args),
                    },
                  })
                end
              end
            end
          end

          if #parsed_tool_calls > 0 then
            -- Strip tool call text before passing
            local clean_text = text:gsub("<tool_call>.-</tool_call>", "")
            clean_text = clean_text:gsub('%{"function":%s*".-"%s*,%s*"arguments":%s*%b{}%s*%}', "")
            clean_text = clean_text:gsub("^%s+", ""):gsub("%s+$", "")
            if on_done then on_done(clean_text, stats, parsed_tool_calls) end
          else
            if on_done then on_done(text, stats, nil) end
          end
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
  local max_rounds = opts.max_rounds or 10
  local round = 0
  local consecutive_errors = 0
  local max_consecutive_errors = 3

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
          -- Track consecutive errors
          if is_error then
            consecutive_errors = consecutive_errors + 1
          else
            consecutive_errors = 0
          end

          -- Add tool result message (truncate large results to prevent context overflow)
          local content = result_text or ""
          local max_result_len = 3000
          if #content > max_result_len then
            local line_count = select(2, content:gsub("\n", "\n"))
            content = content:sub(1, max_result_len)
              .. string.format("\n\n[truncated: showing first %d chars of %d, ~%d lines total]",
                max_result_len, #result_text, line_count)
          end
          table.insert(messages, {
            role = "tool",
            tool_call_id = tc.id,
            content = content,
          })

          if opts.on_tool_display then
            opts.on_tool_display(tc, is_error and "error" or "done", result_text)
          end

          -- Stop if too many consecutive errors
          if consecutive_errors >= max_consecutive_errors then
            vim.schedule(function()
              vim.notify("neocode: stopped — " .. consecutive_errors .. " consecutive tool errors", vim.log.levels.WARN)
              -- Add a message telling the model to stop using tools
              table.insert(messages, {
                role = "assistant",
                content = "I've encountered multiple tool errors. Let me answer based on what I know.",
              })
              if on_done then on_done("", {}, nil) end
            end)
            return
          end

          -- Process next tool call
          process_next(i + 1)
        end)
      end

      process_next(1)
    end, { tools = opts.tools, cwd = opts.cwd })
  end

  return do_round()
end

return M
