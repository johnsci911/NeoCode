local M = {}
local vim = _G.vim

M.name = "local"
M.type = "api"
M.session_store = true

M.defaults = {
  provider = "openai_compatible",
  base_url = "http://127.0.0.1:8080/v1",
  model = "local",
  context_size = 32768,
  temperature = 0.2,
  max_tokens = 4096,
  max_tool_rounds = 5,
}

local function provider_module(name)
  if name == "llama_server" or name == "llama-server" then
    return require("neocode.providers.llama_server"), "llama_server"
  end
  return require("neocode.providers.openai_compatible"), "openai_compatible"
end

local function ensure_setup()
  if not M.config then M.setup({}) end
end

function M.setup(opts)
  opts = opts or {}
  local explicit_model = opts.model ~= nil
  local explicit_context_size = opts.context_size ~= nil
  M.config = vim.tbl_deep_extend("force", M.defaults, opts or {})
  local provider_factory, normalized_name = provider_module(M.config.provider)
  M.config.provider = normalized_name
  M.provider = provider_factory.setup({
    base_url = M.config.base_url,
    model = M.config.model,
    fallback_context_size = M.config.context_size,
    probe = M.config.provider_probe,
    read_json = M.config.read_json,
  })
  local metadata = M.provider.probe_metadata and M.provider:probe_metadata() or nil
  if type(metadata) == "table" then
    if not explicit_model and metadata.model and metadata.model ~= "" then
      M.config.model = metadata.model
    end
    if not explicit_context_size and tonumber(metadata.context_size) then
      M.config.context_size = tonumber(metadata.context_size)
    end
    M.config.estimated_context_size = metadata.estimated_context_size == true
  end
  M.base_url = M.provider.base_url
  M.model = M.config.model or M.provider.model
  return M
end

function M._build_user_message(text, image_b64)
  if image_b64 and image_b64 ~= "" then
    return {
      role = "user",
      content = {
        { type = "text", text = text or "" },
        {
          type = "image_url",
          image_url = { url = "data:image/png;base64," .. image_b64 },
        },
      },
    }
  end

  return { role = "user", content = text or "" }
end

local function response_text_from_result(result)
  if type(result) ~= "table" then return "" end
  if result.error then
    local err = result.error
    local message = type(err) == "table" and (err.message or err.code) or err
    return "Local model request failed: " .. tostring(message or "unknown error")
  end
  local choice = result.choices and result.choices[1]
  local message = choice and choice.message or {}
  return message.content or message.reasoning_content or result.content or ""
end

local function message_from_result(result)
  if type(result) ~= "table" then return nil end
  local choice = result.choices and result.choices[1]
  return choice and choice.message or nil
end

local function stats_from_result(result)
  local usage = type(result) == "table" and result.usage or nil
  local stats = {
    provider = M.config and M.config.provider or "openai_compatible",
    model = M.model,
    context_size = M.config and M.config.context_size,
  }
  if type(result) == "table" and result.error then
    stats.error = true
  end
  if type(usage) == "table" then
    stats.usage = usage
  end
  return stats
end

function M._complete_from_result(result)
  return response_text_from_result(result), stats_from_result(result)
end

local function request_payload(messages, extra)
  ensure_setup()
  extra = extra or {}
  local payload = {
    model = M.model,
    messages = messages,
    stream = false,
    temperature = M.config.temperature,
    max_tokens = M.config.max_tokens,
    enable_thinking = false,
    chat_template_kwargs = { enable_thinking = false },
  }
  if extra.tools and #extra.tools > 0 then
    payload.tools = extra.tools
  end
  return payload
end

local function default_transport(messages, extra, callback)
  ensure_setup()
  local payload = vim.fn.json_encode(request_payload(messages, extra))
  local url = M.provider:chat_completions_url()
  local stdout = {}
  local stderr = {}
  local completed = false

  local function complete(result)
    if completed then return end
    completed = true
    callback(result)
  end

  return vim.fn.jobstart({
    "curl", "--silent", "--show-error", "--fail-with-body",
    "-X", "POST",
    "-H", "Content-Type: application/json",
    "-d", payload,
    "--", url,
  }, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      stdout = data or {}
    end,
    on_stderr = function(_, data)
      stderr = data or {}
    end,
    on_exit = function(_, code)
      local raw = table.concat(stdout or {}, "")
      local err = table.concat(stderr or {}, "")
      local ok, result = pcall(vim.fn.json_decode, raw)
      if code ~= 0 then
        if ok and type(result) == "table" and result.error then
          complete(result)
        else
          complete({
            error = {
              message = (raw ~= "" and raw) or (err ~= "" and err) or "curl exited with code " .. tostring(code),
            },
          })
        end
        vim.notify("neocode: local model request failed", vim.log.levels.WARN)
        return
      end

      if ok then
        complete(result)
      else
        complete({ content = raw })
      end
    end,
  })
end

local function request_once(messages, extra, callback)
  local transport = M._transport or default_transport
  return transport(messages, extra or {}, callback)
end

local function start_request(messages, on_complete, extra)
  return request_once(messages, extra, function(result)
    local text, stats = M._complete_from_result(result)
    on_complete(text, stats)
  end)
end

function M.stream(messages, _, on_complete)
  return start_request(messages, on_complete, nil)
end

function M.stream_with_tools(messages, _, on_complete, opts)
  ensure_setup()
  opts = opts or {}
  local working_messages = vim.deepcopy(messages or {})
  local max_rounds = M.config.max_tool_rounds or 5
  local job_id = nil

  local function finish(result)
    local text, stats = M._complete_from_result(result)
    on_complete(text, stats)
  end

  local function continue_after_tools(tool_calls, round_num)
    local pending = #tool_calls
    if pending == 0 then return end

    for _, tool_call in ipairs(tool_calls) do
      if opts.on_tool_display then
        opts.on_tool_display(tool_call, "running", nil)
      end

      local function tool_done(result_text, is_error)
        local content = result_text or ""
        table.insert(working_messages, {
          role = "tool",
          tool_call_id = tool_call.id,
          name = (tool_call["function"] or {}).name,
          content = content,
        })
        if opts.on_tool_display then
          opts.on_tool_display(tool_call, is_error and "error" or "done", content)
        end
        pending = pending - 1
        if pending == 0 then
          if opts.on_round_start then opts.on_round_start(round_num + 1) end
          job_id = request_once(working_messages, { tools = opts.tools }, function(next_result)
            local next_message = message_from_result(next_result)
            local next_tool_calls = next_message and next_message.tool_calls or nil
            if next_tool_calls and #next_tool_calls > 0 and round_num < max_rounds then
              table.insert(working_messages, {
                role = "assistant",
                content = next_message and next_message.content or nil,
                tool_calls = next_tool_calls,
              })
              continue_after_tools(next_tool_calls, round_num + 1)
            else
              finish(next_result)
            end
          end)
        end
      end

      if opts.on_tool_call then
        opts.on_tool_call(tool_call, tool_done)
      else
        tool_done("Tool execution callback is not configured", true)
      end
    end
  end

  job_id = request_once(working_messages, { tools = opts.tools }, function(result)
    local message = message_from_result(result)
    local tool_calls = message and message.tool_calls or nil
    if tool_calls and #tool_calls > 0 then
      table.insert(working_messages, {
        role = "assistant",
        content = message and message.content or nil,
        tool_calls = tool_calls,
      })
      continue_after_tools(tool_calls, 1)
    else
      finish(result)
    end
  end)
  return job_id
end

M._request_payload = request_payload

M.setup({})

return M
