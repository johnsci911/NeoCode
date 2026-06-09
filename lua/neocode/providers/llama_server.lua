local openai = require("neocode.providers.openai_compatible")

local M = {}

M.defaults = {
  base_url = "http://127.0.0.1:8080/v1",
  fallback_context_size = 32768,
}

local Provider = {}
Provider.__index = Provider

local function trim_trailing_slashes(value)
  return tostring(value or ""):gsub("/+$", "")
end

local function normalize_server_url(base_url)
  local normalized = trim_trailing_slashes(base_url ~= nil and base_url or M.defaults.base_url)
  if normalized == "" then normalized = M.defaults.base_url end
  return normalized:gsub("/v1$", "")
end

local function read_url_json(url)
  local output = vim.fn.system({ "curl", "--silent", "--show-error", "--max-time", "3", "--", url })
  if vim.v.shell_error ~= 0 or output == "" then return nil end
  local ok, data = pcall(vim.fn.json_decode, output)
  if ok and type(data) == "table" then return data end
  return nil
end

local function props_thinking_available(props)
  if type(props) ~= "table" then return nil end
  if type(props.thinking_available) == "boolean" then return props.thinking_available end
  local caps = props.chat_template_caps
  if type(caps) == "table" then
    if type(caps.supports_thinking) == "boolean" then return caps.supports_thinking end
    if type(caps.supports_enable_thinking) == "boolean" then return caps.supports_enable_thinking end
  end
  return nil
end

function M.metadata_from_responses(props, models, opts)
  opts = opts or {}
  local base = openai.metadata_from_models(models, {
    fallback_context_size = opts.fallback_context_size or M.defaults.fallback_context_size,
  })

  local model_info = openai._first_model(models) or {}
  local meta = model_info.meta or {}
  local generation = type(props) == "table" and props.default_generation_settings or {}
  local context_size = tonumber(generation.n_ctx)
    or tonumber(type(props) == "table" and props.n_ctx)
    or tonumber(meta.n_ctx)
    or tonumber(meta.n_ctx_train)
    or base.context_size
  local thinking_available = props_thinking_available(props)
  if thinking_available == nil and type(base.thinking_available) == "boolean" then
    thinking_available = base.thinking_available
  end

  return {
    provider = "llama-server",
    model = type(props) == "table" and (props.model_alias or props.model or props.model_name)
      or base.model,
    context_size = context_size,
    training_context_size = base.training_context_size or tonumber(meta.n_ctx_train),
    estimated_context_size = not (tonumber(generation.n_ctx)
      or tonumber(type(props) == "table" and props.n_ctx)
      or tonumber(meta.n_ctx)
      or tonumber(meta.n_ctx_train)),
    thinking_available = thinking_available == true,
  }
end

function Provider:props_url()
  return self.server_url .. "/props"
end

function Provider:models_url()
  return self.server_url .. "/v1/models"
end

function Provider:native_models_url()
  return self.server_url .. "/models"
end

function Provider:slots_url()
  return self.server_url .. "/slots"
end

function Provider:chat_completions_url()
  return self.server_url .. "/v1/chat/completions"
end

function M.setup(opts)
  opts = opts or {}
  local server_url = normalize_server_url(opts.base_url)
  local instance = {
    name = "llama_server",
    base_url = server_url .. "/v1",
    server_url = server_url,
    model = opts.model,
    fallback_context_size = opts.fallback_context_size or M.defaults.fallback_context_size,
    probe = opts.probe,
    read_json = opts.read_json or read_url_json,
  }
  return setmetatable(instance, Provider)
end

function Provider:probe_metadata()
  if type(self.probe) == "function" then
    return self.probe(self)
  end
  local props = self.read_json and self.read_json(self:props_url()) or nil
  local models = self.read_json and self.read_json(self:models_url()) or nil
  if not props and not models then return nil end
  return M.metadata_from_responses(props, models, { fallback_context_size = self.fallback_context_size })
end

M._normalize_server_url = normalize_server_url

return M
