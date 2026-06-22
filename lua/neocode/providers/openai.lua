local M = {}

M.defaults = {
  base_url = "https://api.openai.com/v1",
  fallback_context_size = 128000,
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

local function env(name)
  if type(name) ~= "string" or name == "" then return nil end
  local value = vim.fn.getenv(name)
  if value == vim.NIL or value == "" then return nil end
  return value
end

local function model_rank(id)
  id = tostring(id or ""):lower()
  if not id:match("^gpt") then return nil end
  if id:match("audio") or id:match("realtime") or id:match("transcribe") or id:match("tts") then return nil end
  if id:match("embedding") or id:match("image") or id:match("search") or id:match("moderation") then return nil end
  if id:match("mini") then return 90 end
  if id:match("nano") then return 80 end
  return 70
end

local function choose_chat_model(models)
  local data = type(models) == "table" and models.data or nil
  if type(data) ~= "table" then return nil end
  local best = nil
  local best_rank = -1
  for _, model in ipairs(data) do
    local id = type(model) == "table" and model.id or nil
    local rank = model_rank(id)
    if rank and rank > best_rank then
      best = model
      best_rank = rank
    end
  end
  return best
end

local function read_url_json(url, opts)
  opts = opts or {}
  local argv = { "curl", "--silent", "--show-error", "--max-time", "5" }
  for key, value in pairs(opts.headers or {}) do
    table.insert(argv, "-H")
    table.insert(argv, tostring(key) .. ": " .. tostring(value))
  end
  table.insert(argv, "--")
  table.insert(argv, url)
  local output = vim.fn.system(argv)
  if vim.v.shell_error ~= 0 or output == "" then return nil end
  local ok, data = pcall(vim.fn.json_decode, output)
  if ok and type(data) == "table" then return data end
  return nil
end

function M.metadata_from_models(models, opts)
  opts = opts or {}
  local model_info = choose_chat_model(models) or {}
  return {
    provider = "openai",
    model = model_info.id,
    context_size = tonumber(opts.fallback_context_size or M.defaults.fallback_context_size),
    estimated_context_size = true,
    thinking_available = false,
  }
end

function Provider:chat_completions_url()
  return self.base_url .. "/chat/completions"
end

function Provider:models_url()
  return self.base_url .. "/models"
end

function Provider:headers()
  local headers = {}
  if self.api_key and self.api_key ~= "" then
    headers.Authorization = "Bearer " .. self.api_key
  end
  if self.organization and self.organization ~= "" then
    headers["OpenAI-Organization"] = self.organization
  end
  if self.project and self.project ~= "" then
    headers["OpenAI-Project"] = self.project
  end
  return headers
end

function Provider:curl_auth_args()
  local args = {}
  for key, value in pairs(self:headers()) do
    table.insert(args, "-H")
    table.insert(args, tostring(key) .. ": " .. tostring(value))
  end
  return args
end

function M.setup(opts)
  opts = opts or {}
  local instance = {
    name = "openai",
    base_url = normalize_base_url(opts.base_url),
    model = opts.model,
    api_key = opts.api_key or env(opts.api_key_env or "OPENAI_API_KEY"),
    organization = opts.organization or env(opts.organization_env or "OPENAI_ORGANIZATION"),
    project = opts.project or env(opts.project_env or "OPENAI_PROJECT"),
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
  local models = self.read_json and self.read_json(self:models_url(), { headers = self:headers() }) or nil
  if not models then return nil end
  return M.metadata_from_models(models, { fallback_context_size = self.fallback_context_size })
end

M._normalize_base_url = normalize_base_url
M._choose_chat_model = choose_chat_model

return M
