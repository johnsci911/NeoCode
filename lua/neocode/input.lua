local M = {}

-- Open a floating input buffer for composing multi-line prompts.
-- On <C-s> or <leader><CR>: sends content to the CLI via chansend, closes window.
-- On <Esc> (normal mode): cancels without sending.
function M.open(session, config)
  if not session then
    vim.notify("neocode: no active session", vim.log.levels.WARN)
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype    = "markdown"
  vim.bo[buf].bufhidden   = "wipe"

  local width  = math.floor(vim.o.columns * 0.7)
  local height = math.floor(vim.o.lines * 0.4)
  local row    = math.floor((vim.o.lines - height) / 2)
  local col    = math.floor((vim.o.columns - width) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row      = row,
    col      = col,
    width    = width,
    height   = height,
    style    = "minimal",
    border   = "rounded",
    title    = " NeoCode Input — <C-s>/<M-CR> send · <Esc> cancel ",
    title_pos = "center",
  })

  vim.wo[win].wrap      = true
  vim.wo[win].linebreak = true

  -- Start in insert mode
  vim.cmd("startinsert")

  local function send_and_close()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text  = table.concat(lines, "\n")
    if text == "" then
      vim.api.nvim_win_close(win, true)
      return
    end
    if not session.job_id then
      vim.notify("neocode: session has no active job (job_id is nil)", vim.log.levels.ERROR)
      return
    end
    vim.api.nvim_win_close(win, true)
    -- Focus back to the terminal buffer before sending
    if session.bufnr and vim.api.nvim_buf_is_valid(session.bufnr) then
      vim.api.nvim_set_current_buf(session.bufnr)
    end
    vim.fn.chansend(session.job_id, text .. "\n")
  end

  local function cancel()
    vim.api.nvim_win_close(win, true)
  end

  -- Send: <C-s> in both modes (may be blocked by terminal — use <M-CR> as fallback)
  vim.keymap.set("i", "<C-s>",  send_and_close, { buffer = buf, silent = true })
  vim.keymap.set("n", "<C-s>",  send_and_close, { buffer = buf, silent = true })
  -- Alt+Enter as reliable fallback send (not intercepted by terminal)
  vim.keymap.set("i", "<M-CR>", send_and_close, { buffer = buf, silent = true })
  vim.keymap.set("n", "<M-CR>", send_and_close, { buffer = buf, silent = true })

  -- Cancel: <Esc> in normal mode
  vim.keymap.set("n", "<Esc>", cancel, { buffer = buf, silent = true })
end

return M
