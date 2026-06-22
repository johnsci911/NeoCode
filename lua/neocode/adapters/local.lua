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
  thinking = "off",
  thinking_available = nil,
}

local THINKING_PRESETS = {
  off = { enable_thinking = false, thinking_budget_tokens = 0 },
  low = { enable_thinking = true, reasoning_effort = "low", thinking_budget_tokens = 512 },
  medium = { enable_thinking = true, reasoning_effort = "medium", thinking_budget_tokens = 2048 },
  high = { enable_thinking = true, reasoning_effort = "high", thinking_budget_tokens = 8192 },
  max = { enable_thinking = true, reasoning_effort = nil, thinking_budget_tokens = nil },
}

local function provider_module(name)
  if name == "openai" then
    return require("neocode.providers.openai"), "openai"
  end
  if name == "llama_server" or name == "llama-server" then
    return require("neocode.providers.llama_server"), "llama_server"
  end
  return require("neocode.providers.openai_compatible"), "openai_compatible"
end

local function apply_metadata(metadata, explicit_model, explicit_context_size, explicit_thinking_available)
  if type(metadata) ~= "table" then return end
  if not explicit_model and metadata.model and metadata.model ~= "" then
    M.config.model = metadata.model
  end
  if not explicit_context_size and tonumber(metadata.context_size) then
    M.config.context_size = tonumber(metadata.context_size)
  end
  M.config.estimated_context_size = metadata.estimated_context_size == true
  if not explicit_thinking_available and type(metadata.thinking_available) == "boolean" then
    M.config.thinking_available = metadata.thinking_available
  end
  if type(metadata.thinking_source) == "string" and metadata.thinking_source ~= "" then
    M.config.thinking_source = metadata.thinking_source
  end
  if type(metadata.reasoning_format) == "string" and metadata.reasoning_format ~= "" then
    M.config.reasoning_format = metadata.reasoning_format
  end
end

local function ensure_setup()
  if not M.config then M.setup({}) end
end

local function normalize_thinking_mode(mode)
  local normalized = tostring(mode or "off"):lower()
  if normalized == "none" or normalized == "false" or normalized == "0" then normalized = "off" end
  if THINKING_PRESETS[normalized] then return normalized end
  return nil
end

function M._is_thinking_model(_, config)
  config = config or M.config or {}
  if type(config.thinking_available) == "boolean" then return config.thinking_available end
  return false
end

function M.thinking_available()
  ensure_setup()
  return M._is_thinking_model(M.model, M.config) == true
end

function M.thinking_mode()
  ensure_setup()
  return normalize_thinking_mode(M.config.thinking) or "off"
end

function M.set_thinking(mode)
  ensure_setup()
  local normalized = normalize_thinking_mode(mode)
  if not normalized then
    return false, "usage: /thinking off|low|medium|high|max"
  end
  if normalized ~= "off" and not M.thinking_available() then
    return false, "Thinking mode not available"
  end
  M.config.thinking = normalized
  local source = M.config.thinking_source
  if normalized ~= "off" and type(source) == "string" and source ~= "" then
    return true, "thinking mode: " .. normalized .. " (enabled for next request; confirmed by " .. source .. ")"
  end
  if normalized ~= "off" then
    return true, "thinking mode: " .. normalized .. " (enabled for next request)"
  end
  return true, "thinking mode: off"
end

function M._thinking_payload(mode, model, config)
  mode = normalize_thinking_mode(mode)
  config = config or M.config or {}
  if not M._is_thinking_model(model, config) then
    return {}
  end
  if not mode or mode == "off" then
    return {
      enable_thinking = false,
      chat_template_kwargs = { enable_thinking = false },
      thinking_budget_tokens = 0,
    }
  end

  local preset = THINKING_PRESETS[mode]
  local kwargs = { enable_thinking = true }
  if preset.reasoning_effort then kwargs.reasoning_effort = preset.reasoning_effort end
  local payload = {
    enable_thinking = true,
    chat_template_kwargs = kwargs,
  }
  if type(config.reasoning_format) == "string" and config.reasoning_format ~= "" and config.reasoning_format ~= "none" then
    payload.reasoning_format = config.reasoning_format
  end
  if preset.thinking_budget_tokens then payload.thinking_budget_tokens = preset.thinking_budget_tokens end
  return payload
end

local function trim_response(text)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function strip_leaked_preamble(text)
  local first_line = text:match("^([^\n]*)") or text
  local noisy_prefix = first_line:match("^%s*[%p%c]*[%w%p%s]-[%w]%-[%w]%-")
    or first_line:match("^%s*[%p%c]*[%w%p%s]-%-.-%-.-%-.-%-")
  if not noisy_prefix then return text end

  local starts = { "It%s+", "Here%s+", "To%s+", "The%s+", "This%s+", "For%s+", "If%s+", "You%s+", "I%s+" }
  for _, pattern in ipairs(starts) do
    local start_at = text:find(pattern, 12)
    if start_at then return text:sub(start_at) end
  end
  return text
end

local function strip_reserved_tokens(text)
  local cleaned = text
  cleaned = cleaned:gsub("<｜begin▁of▁sentence｜>", "")
  cleaned = cleaned:gsub("<|start_header_id|>assistant<|end_header_id|>", "")
  cleaned = cleaned:gsub("<|start_header_id|>user<|end_header_id|>", "")
  cleaned = cleaned:gsub("<|start_header_id|>system<|end_header_id|>", "")
  cleaned = cleaned:gsub("<|eot_id|>", "")
  cleaned = cleaned:gsub("<|channel|>", "")
  cleaned = cleaned:gsub("<|channel>", "")
  cleaned = cleaned:gsub("<channel|>", "")
  cleaned = cleaned:gsub("<|message|>", "")
  return cleaned
end

local function has_reserved_reasoning_artifact(text)
  return text:find("<|channel>thought", 1, true)
    or text:find("<|channel|>thought", 1, true)
    or text:find("<channel|>", 1, true)
    or text:find("<|start_header_id|>", 1, true)
end

local function looks_like_pathological_reasoning(text)
  local thought_count = 0
  for _ in text:gmatch("thought") do
    thought_count = thought_count + 1
    if thought_count >= 8 then return true end
  end
  return text:match("[%w%-]+%-[%w%-]+%-[%w%-]+%-[%w%-]+%-[%w%-]+%-[%w%-]+") ~= nil
end

local function first_final_sentence(text)
  local starts = { "It%s+", "Here%s+", "To%s+", "The%s+", "This%s+", "For%s+", "If%s+", "You%s+", "I%s+" }
  for _, pattern in ipairs(starts) do
    local start_at = text:find(pattern)
    if start_at then return text:sub(start_at) end
  end
  return nil
end

local function normalize_escaped_markdown_fences(text)
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local normalized = line:gsub("^(%s*)\\```", "%1```")
    table.insert(lines, normalized)
  end
  return table.concat(lines, "\n")
end

local function sanitize_text(text)
  if type(text) ~= "string" or text == "" then return "" end
  local cleaned = text:gsub("\r\n", "\n")
  local had_artifact = has_reserved_reasoning_artifact(cleaned)
  cleaned = cleaned:gsub("<[Tt][Hh][Ii][Nn][Kk]>.-</[Tt][Hh][Ii][Nn][Kk]>", "")
  cleaned = cleaned:gsub("<[Tt][Hh][Ii][Nn][Kk]>.*$", "")
  cleaned = cleaned:gsub("<analysis>.-</analysis>", "")
  cleaned = cleaned:gsub("<analysis>.*$", "")
  cleaned = cleaned:gsub("<reasoning>.-</reasoning>", "")
  cleaned = cleaned:gsub("<reasoning>.*$", "")
  cleaned = strip_reserved_tokens(cleaned)
  cleaned = trim_response(cleaned)
  if had_artifact or looks_like_pathological_reasoning(cleaned) then
    cleaned = first_final_sentence(cleaned) or ""
  end
  cleaned = strip_leaked_preamble(cleaned)
  cleaned = normalize_escaped_markdown_fences(cleaned)
  return trim_response(cleaned)
end

local function sanitize_content(content)
  if type(content) == "string" then
    return sanitize_text(content)
  end
  if type(content) ~= "table" then return content end

  local clean_parts = {}
  for _, part in ipairs(content) do
    local clean_part = vim.deepcopy(part)
    if type(clean_part) == "table" and clean_part.type == "text" then
      clean_part.text = sanitize_text(clean_part.text or "")
    end
    table.insert(clean_parts, clean_part)
  end
  return clean_parts
end

local function sanitize_message(msg)
  if type(msg) ~= "table" then return nil end
  local clean = vim.deepcopy(msg)
  clean.reasoning_content = nil
  clean.content = sanitize_content(clean.content)
  if clean.role == "assistant" and (clean.content == nil or clean.content == "") and not clean.tool_calls then
    return nil
  end
  return clean
end

local function sanitize_messages(messages)
  local clean = {}
  for _, msg in ipairs(messages or {}) do
    local sanitized = sanitize_message(msg)
    if sanitized then table.insert(clean, sanitized) end
  end
  return clean
end

function M.setup(opts)
  opts = opts or {}
  local explicit_provider = opts.provider ~= nil
  local explicit_base_url = opts.base_url ~= nil
  local explicit_model = opts.model ~= nil
  local explicit_context_size = opts.context_size ~= nil
  local explicit_thinking_available = opts.thinking_available ~= nil
  M._explicit_model = explicit_model
  M._explicit_context_size = explicit_context_size
  M._explicit_thinking_available = explicit_thinking_available
  M.config = vim.tbl_deep_extend("force", M.defaults, opts or {})
  local provider_factory, normalized_name = provider_module(M.config.provider)
  M.config.provider = normalized_name
  local provider_base_url = M.config.base_url
  if normalized_name == "openai" and not explicit_base_url then
    provider_base_url = nil
  end
  M.provider = provider_factory.setup({
    base_url = provider_base_url,
    model = M.config.model,
    fallback_context_size = M.config.context_size,
    probe = M.config.provider_probe,
    read_json = M.config.read_json,
    api_key = M.config.api_key,
    api_key_env = M.config.api_key_env,
    organization = M.config.organization,
    organization_env = M.config.organization_env,
    project = M.config.project,
    project_env = M.config.project_env,
  })
  local metadata = M.provider.probe_metadata and M.provider:probe_metadata() or nil
  if not explicit_provider and normalized_name == "openai_compatible" then
    local llama_provider_factory = require("neocode.providers.llama_server")
    local llama_provider = llama_provider_factory.setup({
      base_url = M.config.base_url,
      model = M.config.model,
      fallback_context_size = M.config.context_size,
      probe = M.config.provider_probe,
      read_json = M.config.read_json,
    })
    local llama_metadata = llama_provider.probe_metadata and llama_provider:probe_metadata() or nil
    if type(llama_metadata) == "table" and (
      llama_metadata.thinking_available == true
      or llama_metadata.provider == "llama-server"
      or tonumber(llama_metadata.context_size)
    ) then
      M.provider = llama_provider
      M.config.provider = "llama_server"
      metadata = llama_metadata
    end
  end
  apply_metadata(metadata, explicit_model, explicit_context_size, explicit_thinking_available)
  M.base_url = M.provider.base_url
  M.model = M.config.model or M.provider.model
  return M
end

function M.new(opts)
  opts = opts or {}
  if opts.lazy then
    local setup_opts = vim.tbl_extend("force", {}, opts)
    setup_opts.lazy = nil
    local instance = {
      name = opts.name or M.name,
      type = M.type,
      session_store = M.session_store,
      config = vim.tbl_deep_extend("force", M.defaults, setup_opts),
      provider_name = opts.provider,
    }

    local function activate()
      M.setup(setup_opts)
      instance.config = M.config
      instance.base_url = M.base_url
      instance.model = M.model
      return M
    end

    instance.refresh_metadata = function(...) return activate().refresh_metadata(...) end
    instance.stream = function(...) return activate().stream(...) end
    instance.stream_with_tools = function(...) return activate().stream_with_tools(...) end
    instance._build_user_message = function(...) return activate()._build_user_message(...) end
    instance.thinking_available = function(...) return activate().thinking_available(...) end
    instance.thinking_mode = function(...) return activate().thinking_mode(...) end
    instance.set_thinking = function(...) return activate().set_thinking(...) end
    return instance
  end

  M.setup(opts)
  local instance = vim.tbl_extend("force", {}, M)
  instance.name = opts.name or M.name
  return instance
end

function M.refresh_metadata()
  ensure_setup()
  if not (M.provider and M.provider.probe_metadata) then return false end
  local metadata = M.provider:probe_metadata()
  if type(metadata) ~= "table" then return false end
  apply_metadata(metadata, M._explicit_model, M._explicit_context_size, M._explicit_thinking_available)
  M.base_url = M.provider.base_url
  M.model = M.config.model or M.provider.model
  return true, metadata
end

function M._build_user_message(text, images_b64)
  local image_list = {}
  if type(images_b64) == "table" then
    image_list = images_b64
  elseif images_b64 and images_b64 ~= "" then
    image_list = { images_b64 }
  end

  if #image_list > 0 then
    local content = { { type = "text", text = text or "" } }
    for _, image_b64 in ipairs(image_list) do
      if image_b64 and image_b64 ~= "" then
        table.insert(content, {
          type = "image_url",
          image_url = { url = "data:image/png;base64," .. image_b64 },
        })
      end
    end

    return {
      role = "user",
      content = content,
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
  return sanitize_text(message.content or result.content or "")
end

local function message_from_result(result)
  if type(result) ~= "table" then return nil end
  local choice = result.choices and result.choices[1]
  return choice and choice.message or nil
end

local function stats_from_result(result)
  local usage = type(result) == "table" and result.usage or nil
  local message = message_from_result(result) or {}
  local error_message = nil
  if type(result) == "table" and result.error then
    error_message = type(result.error) == "table" and result.error.message or result.error
  end
  local stats = {
    provider = M.config and M.config.provider or "openai_compatible",
    model = M.model,
    context_size = M.config and M.config.context_size,
    thinking_mode = M.config and M.config.thinking or nil,
  }
  if type(message.reasoning_content) == "string" and message.reasoning_content ~= "" then
    stats.thinking_confirmed = true
  end
  if type(result) == "table" and result.error then
    stats.error = true
  end
  if type(usage) == "table" then
    stats.usage = usage
  end
  if type(error_message) == "string" then
    local requested, available = error_message:match("request%s*%((%d+)%s+tokens%)%s+exceeds%s+the%s+available%s+context%s+size%s*%((%d+)%s+tokens%)")
    requested = tonumber(requested)
    available = tonumber(available)
    if requested and available then
      stats.context_size = available
      stats.usage = {
        prompt_tokens = requested,
        completion_tokens = 0,
        total_tokens = requested,
      }
    end
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
    messages = sanitize_messages(messages),
    stream = false,
    temperature = M.config.temperature,
    max_tokens = M.config.max_tokens,
  }
  payload = vim.tbl_deep_extend("force", payload, M._thinking_payload(M.config.thinking, M.model, M.config))
  if extra.tools and #extra.tools > 0 then
    payload.tools = extra.tools
  end
  return payload
end

local function default_transport(messages, extra, callback)
  ensure_setup()
  local payload = vim.fn.json_encode(request_payload(messages, extra))
  local payload_path = vim.fn.tempname()
  local payload_file = io.open(payload_path, "w")
  if not payload_file then
    callback({ error = { message = "could not write request payload" } })
    return nil
  end
  payload_file:write(payload)
  payload_file:close()
  local url = M.provider:chat_completions_url()
  local stdout = {}
  local stderr = {}
  local completed = false

  local function cleanup_payload()
    if payload_path then
      pcall(vim.fn.delete, payload_path)
      payload_path = nil
    end
  end

  local function complete(result)
    if completed then return end
    completed = true
    cleanup_payload()
    callback(result)
  end

  local argv = {
    "curl", "--silent", "--show-error", "--fail-with-body",
    "-X", "POST",
    "-H", "Content-Type: application/json",
  }
  if M.provider and M.provider.curl_auth_args then
    for _, arg in ipairs(M.provider:curl_auth_args()) do
      table.insert(argv, arg)
    end
  end
  table.insert(argv, "--data-binary")
  table.insert(argv, "@" .. payload_path)
  table.insert(argv, "--")
  table.insert(argv, url)

  return vim.fn.jobstart(argv, {
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
                content = next_message and sanitize_content(next_message.content) or nil,
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
        content = message and sanitize_content(message.content) or nil,
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
M._sanitize_text = sanitize_text
M._sanitize_messages = sanitize_messages

return M
