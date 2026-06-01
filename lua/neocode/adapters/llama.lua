-- lua/neocode/adapters/llama.lua
-- Continue CLI adapter for local LLM sessions.
--
-- By default NeoCode only launches Continue. When explicitly enabled,
-- it can generate a small Continue config from llama-server metadata before
-- launch so Continue sees the server's current model and runtime context.
local M = {}

M.name = "llama"
M.session_store = true

M.defaults = {
  command = "cn",
  args = {},
  dynamic_continue_config = {
    enabled = false,
    llama_server = "http://127.0.0.1:8080",
    output = nil,
    name = "Local Llama",
    max_tokens = 3500,
  },
}

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.defaults, opts or {})
end

local function config()
  if not M.config then
    M.setup({})
  end
  return M.config
end

local function join_url(base, suffix)
  return (base or ""):gsub("/+$", "") .. suffix
end

local function read_url_json(url)
  -- Use a timeout and check for shell errors
  local output = vim.fn.system({ "curl", "--silent", "--show-error", "--max-time", "3", url })
  if vim.v.shell_error ~= 0 or output == "" then 
    vim.notify(string.format("Failed to fetch URL: %s (Curl error %d)", url, vim.v.shell_error), vim.log.levels.WARN)
    return nil 
  end
  local ok, data = pcall(vim.fn.json_decode, output)
  if ok and type(data) == "table" then return data end
  vim.notify(string.format("Failed to decode JSON from URL: %s", url), vim.log.levels.WARN)
  return nil
end

local function first_model(models)
  if type(models) ~= "table" then return nil end
  if type(models.data) == "table" and type(models.data[1]) == "table" then
    return models.data[1]
  end
  if type(models.models) == "table" and type(models.models[1]) == "table" then
    return models.models[1]
  end
  return nil
end

function M._metadata_from_responses(props, models)
  local model_info = first_model(models) or {}
  local meta = model_info.meta or {}
  local generation = props and props.default_generation_settings or {}

  local model = props and (props.model_alias or props.model or props.model_name)
    or model_info.id
    or model_info.model
    or model_info.name

  local context_length = generation.n_ctx
    or props and props.n_ctx
    or meta.n_ctx
    or meta.n_ctx_train

  -- Ensure context_length is a number for safe use
  context_length = tonumber(context_length) or 1 

  return {
    model = model,
    context_length = context_length,
    training_context_length = tonumber(meta.n_ctx_train) or 1,
  }
end

function M._probe_llama_server(dynamic_cfg)
  dynamic_cfg = dynamic_cfg or {}
  if dynamic_cfg.probe then return dynamic_cfg.probe(dynamic_cfg) end

  local server = dynamic_cfg.llama_server or M.defaults.dynamic_continue_config.llama_server
  
  local props = read_url_json(join_url(server, "/props"))
  if not props then return nil end
  
  local models = read_url_json(join_url(server, "/v1/models"))
  if not models then return nil end

  return M._metadata_from_responses(props, models)
end

local function yaml_string(value)
  value = tostring(value or "")
  if value:match("[#\n]") then
    return string.format("%q", value)
  end
  return value
end

function M._build_continue_config(metadata, dynamic_cfg)
  dynamic_cfg = dynamic_cfg or {}
  local api_base = dynamic_cfg.api_base or join_url(dynamic_cfg.llama_server or M.defaults.dynamic_continue_config.llama_server, "/v1")
  local name = dynamic_cfg.name or M.defaults.dynamic_continue_config.name
  local max_tokens = dynamic_cfg.max_tokens or M.defaults.dynamic_continue_config.max_tokens

  return table.concat({
    "name: " .. yaml_string(name),
    "version: 1.0.0",
    "schema: v1",
    "models:",
    "  - name: " .. yaml_string(name),
    "    provider: openai",
    "    model: " .. yaml_string(metadata.model),
    "    apiBase: " .. yaml_string(api_base),
    "    defaultCompletionOptions:",
    "      contextLength: " .. tostring(metadata.context_length),
    "      maxTokens: " .. tostring(max_tokens),
    "    roles:",
    "      - chat",
    "      - edit",
    "      - apply",
    "",
  }, "\n")
end

local function generated_config_path(dynamic_cfg)
  if dynamic_cfg.output and dynamic_cfg.output ~= "" then
    return vim.fn.expand(dynamic_cfg.output)
  end
  return vim.fn.stdpath("data") .. "/neocode/continue.generated.yaml"
end

function M._write_dynamic_continue_config(dynamic_cfg)
  local metadata = M._probe_llama_server(dynamic_cfg)
  if not metadata or not metadata.model or not metadata.context_length then 
    vim.notify("neocode: Failed to retrieve necessary metadata from llama-server.", vim.log.levels.ERROR)
    return nil 
  end

  local path = generated_config_path(dynamic_cfg)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = io.open(path, "w")
  if not f then 
    vim.notify(string.format("neocode: Could not open file for writing: %s", path), vim.log.levels.ERROR)
    return nil 
  end
  f:write(M._build_continue_config(metadata, dynamic_cfg))
  f:close()
  -- Attempt to set permissions, but don't fail if it fails (platform dependency)
  pcall(vim.fn.setfperm, path, "rw-------")
  return path, metadata
end

function M._with_continue_config_arg(args, path)
  local filtered = {}
  local skip_next = false
  for _, arg in ipairs(args or {}) do
    if skip_next then
      skip_next = false
    elseif arg == "--config" then
      skip_next = true
    elseif type(arg) == "string" and arg:match("^%-%-config=") then
      -- Drop old inline config arg; generated config wins.
    else
      table.insert(filtered, arg)
    end
  end
  -- Ensure the new config argument is added correctly
  table.insert(filtered, "--config")
  table.insert(filtered, path)
  return filtered
end

function M.launch_cmd(opts)
  local cfg = config()
  local args = vim.deepcopy(cfg.args or {})
  local dynamic_cfg = cfg.dynamic_continue_config or {}
  
  if dynamic_cfg.enabled then
    local path, metadata = M._write_dynamic_continue_config(dynamic_cfg)
    if path then
      args = M._with_continue_config_arg(args, path)
      -- Only notify success if the path was generated successfully
      vim.notify(
        string.format("neocode: generated Continue config for %s (%d context)", metadata.model, metadata.context_length),
        vim.log.levels.INFO
      )
    else
      -- If config generation failed, we still proceed with the original args, but warn the user.
      vim.notify("neocode: Failed to generate dynamic Continue config. Launching with existing arguments.", vim.log.levels.WARN)
    end
  end
  
  return {
    cmd = cfg.command,
    args = args,
    env = nil,
    cwd = opts and opts.cwd or vim.fn.getcwd(),
  }
end

function M.resume_cmd(opts)
  return M.launch_cmd(opts)
end

function M.interrupt(session)
  if session and session.job_id then
    local success = vim.fn.chansend(session.job_id, "\x03")
    if not success then
      vim.notify("Failed to send interrupt signal to Llama session.", vim.log.levels.WARN)
    end
  else
    vim.notify("Attempted to interrupt session, but session data is missing.", vim.log.levels.WARN)
  end
end

function M.attach_image(session, path)
  if session and session.job_id and path and path ~= "" then
    local success = vim.fn.chansend(session.job_id, path .. "\n")
    if not success then
      vim.notify("Failed to attach image to Llama session.", vim.log.levels.WARN)
    end
  else
    vim.notify("Attempted to attach image, but session data or path is missing.", vim.log.levels.WARN)
  end
end

return M