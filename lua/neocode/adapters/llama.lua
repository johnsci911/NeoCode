-- lua/neocode/adapters/llama.lua
-- Thin Continue CLI adapter for local LLM sessions.
--
-- NeoCode intentionally does not configure models, prompts, tools, or sampling
-- here. Keep that customization in Continue's config.yaml and let `cn` own the
-- local LLM integration.
local M = {}

M.name = "llama"
M.session_store = true

M.defaults = {
  command = "cn",
  args = {},
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

function M.launch_cmd(opts)
  local cfg = config()
  return {
    cmd = cfg.command,
    args = vim.deepcopy(cfg.args or {}),
    env = nil,
    cwd = opts and opts.cwd or vim.fn.getcwd(),
  }
end

function M.resume_cmd(opts)
  return M.launch_cmd(opts)
end

function M.interrupt(session)
  if session and session.job_id then
    vim.fn.chansend(session.job_id, "\x03")
  end
end

function M.attach_image(session, path)
  if session and session.job_id then
    vim.fn.chansend(session.job_id, path .. "\n")
  end
end

return M
