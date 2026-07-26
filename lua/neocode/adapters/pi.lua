local M = {}

M.name          = "pi"
M.session_store = false

function M.launch_cmd(opts)
  local args = {}
  if opts and opts.name then
    table.insert(args, "--name")
    table.insert(args, opts.name)
  end
  if opts and opts.provider then
    table.insert(args, "--provider")
    table.insert(args, opts.provider)
  end
  if opts and opts.model then
    table.insert(args, "--model")
    table.insert(args, opts.model)
  end
  return {
    cmd  = "pi",
    args = args,
    env  = nil,
    cwd  = opts and opts.cwd or vim.fn.getcwd(),
  }
end

function M.resume_cmd(opts)
  return {
    cmd  = "pi",
    args = { "--resume" },
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
  if session and session.job_id and path and path ~= "" then
    vim.fn.chansend(session.job_id, path .. "\n")
  end
end

return M
