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

local function normalize_base_url(base_url)
  local normalized = trim_trailing_slashes(base_url ~= nil and base_url or M.defaults.base_url)
  if normalized == "" then normalized = M.defaults.base_url end
  if normalized:match("/v1$") then return normalized end
  return normalized .. "/v1"
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

local function read_url_json(url)
  local output = vim.fn.system({ "curl", "--silent", "--show-error", "--max-time", "3", "--", url })
  if vim.v.shell_error ~= 0 or output == "" then return nil end
  local ok, data = pcall(vim.fn.json_decode, output)
  if ok and type(data) == "table" then return data end
  return nil
end

function M.metadata_from_models(models, opts)
  opts = opts or {}
  local model_info = first_model(models) or {}
  local meta = model_info.meta or {}
  local context_size = tonumber(meta.n_ctx or meta.context_length or meta.context_size)
  local estimated = false

  if not context_size then
    context_size = tonumber(opts.fallback_context_size or M.defaults.fallback_context_size)
    estimated = true
  end

  return {
    provider = "openai_compatible",
    model = model_info.id or model_info.model or model_info.name,
    context_size = context_size,
    training_context_size = tonumber(meta.n_ctx_train or meta.training_context_length),
    estimated_context_size = estimated,
  }
end

function Provider:chat_completions_url()
  return self.base_url .. "/chat/completions"
end

function Provider:models_url()
  return self.base_url .. "/models"
end

function M.setup(opts)
  opts = opts or {}
  local instance = {
    name = "openai_compatible",
    base_url = normalize_base_url(opts.base_url),
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
  local models = self.read_json and self.read_json(self:models_url()) or nil
  if not models then return nil end
  return M.metadata_from_models(models, { fallback_context_size = self.fallback_context_size })
end

M._normalize_base_url = normalize_base_url
M._first_model = first_model

return M
