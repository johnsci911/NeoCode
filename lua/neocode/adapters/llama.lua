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
-- Calls on_done(full_response_text) when finished.
function M.stream(messages, bufnr, on_done)
  local cfg = M.config or M.defaults
  local url = cfg.base_url .. "/v1/chat/completions"

  -- Filter out empty assistant messages to avoid conflicts with thinking mode
  local filtered = {}
  for _, msg in ipairs(messages) do
    if not (msg.role == "assistant" and (msg.content == nil or msg.content == "")) then
      table.insert(filtered, msg)
    end
  end

  local payload = vim.fn.json_encode({
    model = cfg.model,
    messages = filtered,
    stream = true,
  })

  local full_response = {}
  local partial_line = ""

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
        if ok and chunk.choices and chunk.choices[1] then
          local delta = chunk.choices[1].delta
          -- Skip thinking/reasoning tokens, only render actual content
          local content = delta and delta.content
          if content and type(content) == "string" and content ~= "" then
            table.insert(full_response, content)
            vim.schedule(function()
              local f = io.open("/tmp/neocode_debug.log", "a")
              if f then f:write(vim.inspect(content) .. "\n"); f:close() end
              chat_buffer.append_token(bufnr, content)
              for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
                local lc = vim.api.nvim_buf_line_count(bufnr)
                vim.api.nvim_win_set_cursor(win, { lc, 0 })
              end
            end)
          end
        else
          -- Incomplete JSON line — buffer it
          partial_line = line
        end

        ::continue::
      end
    end,
    on_exit = function(_, exit_code, _)
      vim.schedule(function()
        local text = table.concat(full_response)
        -- Append separator after response
        vim.bo[bufnr].modifiable = true
        local lc = vim.api.nvim_buf_line_count(bufnr)
        vim.api.nvim_buf_set_lines(bufnr, lc, lc, false, { "", "---" })
        vim.bo[bufnr].modifiable = false
        if on_done then on_done(text) end
      end)
    end,
  })

  return job_id
end

return M
