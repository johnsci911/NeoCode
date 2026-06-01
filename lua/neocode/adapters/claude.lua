local M = {}

M.name          = "claude"
M.session_store = true

function M.launch_cmd(opts)
  local args = {}
  if opts and opts.name then
    vim.list_extend(args, { "--name", opts.name })
  end
  return {
    cmd  = "claude",
    args = args,
    env  = nil,
    cwd  = opts and opts.cwd or vim.fn.getcwd(),
    -- Added a timeout option for better robustness
    timeout = 300, 
  }
end

-- Opens Claude's interactive session picker (claude --resume)
function M.resume_cmd(opts)
  return {
    cmd  = "claude",
    args = { "--resume" },
    env  = nil,
    cwd  = opts and opts.cwd or vim.fn.getcwd(),
    timeout = 300,
  }
end

function M.interrupt(session)
  -- Check if the session and job ID exist before attempting to send a signal
  if session and session.job_id then
    -- Send interrupt signal (\x03)
    local success = vim.fn.chansend(session.job_id, "\x03")
    if not success then
      vim.notify("Failed to send interrupt signal to Claude session.", vim.log.levels.WARN)
    end
  else
    vim.notify("Attempted to interrupt session, but session data is missing.", vim.log.levels.WARN)
  end
end

function M.attach_image(session, path)
  -- Check for session and job ID before sending the image path
  if session and session.job_id and path and path ~= "" then
    local success = vim.fn.chansend(session.job_id, path .. "\n")
    if not success then
      vim.notify("Failed to attach image to Claude session.", vim.log.levels.WARN)
    end
  else
    vim.notify("Attempted to attach image, but session data or path is missing.", vim.log.levels.WARN)
  end
end

return M