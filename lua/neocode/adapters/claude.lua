local M = {}

M.name          = "claude"
M.session_store = true

function M.launch_cmd(opts)
  return {
    cmd  = "claude",
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
  if session and session.job_id then
    -- Claude CLI accepts image paths typed into the prompt
    vim.fn.chansend(session.job_id, path .. "\n")
  end
end

return M
