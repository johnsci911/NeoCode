local M = {}

M.name          = "claude"
M.session_store = true

function M.launch_cmd(opts)
  local args = {}
  if opts and opts.session_uuid then
    vim.list_extend(args, { "--session-id", opts.session_uuid })
  end
  if opts and opts.name then
    vim.list_extend(args, { "--name", opts.name })
  end
  return {
    cmd  = "claude",
    args = args,
    env  = nil,
    cwd  = opts and opts.cwd or vim.fn.getcwd(),
  }
end

function M.resume_cmd(opts)
  return {
    cmd  = "claude",
    args = { "--resume", opts.session_uuid },
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
