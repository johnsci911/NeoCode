-- OpenCode adapter — not yet implemented.
-- Placeholder so the adapter directory is complete.
local M = {}

M.name          = "opencode"
M.session_store = false  -- OpenCode manages its own sessions

function M.launch_cmd(opts)
  return {
    cmd  = "opencode",
    args = {},
    env  = nil,
    cwd  = opts and opts.cwd or vim.fn.getcwd(),
  }
end

function M.interrupt(session)
  if session and session.job_id then
    vim.fn.chansend(session.job_id, "\x03")
  end
end

function M.attach_image(session, path)
  -- TODO: confirm OpenCode image attach protocol
end

return M
