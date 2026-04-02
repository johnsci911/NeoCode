-- lua/neocode/adapters/llama.lua
local chat_buffer = require("neocode.chat_buffer")

local M = {}

M.name = "llama"
M.type = "api"       -- signals NeoCode this is not a CLI adapter
M.session_store = true

M.defaults = {
  base_url = "http://localhost:8080",
  model = "qwen3.5-9b",
}

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.defaults, opts or {})
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
function M.stream(messages, bufnr, on_done)
  local cfg = M.config or M.defaults
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

  -- Add system prompt if none exists to reduce hallucination
  if not has_system and cfg.system_prompt ~= false then
    table.insert(filtered, 1, {
      role = "system",
      content = cfg.system_prompt or "You are a helpful assistant. Be concise and accurate. Do not repeat yourself. If you are unsure, say so.",
    })
  end

  local payload = vim.fn.json_encode({
    model = cfg.model,
    messages = filtered,
    stream = true,
    stream_options = { include_usage = true },
    temperature = cfg.temperature or 0.7,
    top_p = cfg.top_p or 0.9,
    repeat_penalty = cfg.repeat_penalty or 1.3,
  })

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
            -- Transition from thinking to generating on first real content
            if thinking then
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
        else
          partial_line = line
        end

        ::continue::
      end
    end,
    on_exit = function(_, exit_code, _)
      vim.schedule(function()
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

        -- Build stats line
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

        if on_done then on_done(text, stats) end
      end)
    end,
  })

  return job_id
end

return M
