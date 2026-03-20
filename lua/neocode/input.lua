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
    title    = " NeoCode Input — <C-s> send · <Esc> cancel ",
    title_pos = "center",
  })

  vim.wo[win].wrap      = true
  vim.wo[win].linebreak = true

  -- Start in insert mode
  vim.cmd("startinsert")

  local function send_and_close()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text  = table.concat(lines, "\n")
    vim.api.nvim_win_close(win, true)
    if text ~= "" and session.job_id then
      vim.fn.chansend(session.job_id, text .. "\n")
    end
  end

  local function cancel()
    vim.api.nvim_win_close(win, true)
  end

  -- Send: <C-s> in both insert and normal mode
  vim.keymap.set("i", "<C-s>", send_and_close, { buffer = buf, silent = true })
  vim.keymap.set("n", "<C-s>", send_and_close, { buffer = buf, silent = true })

  -- Cancel: <Esc> in normal mode
  vim.keymap.set("n", "<Esc>", cancel, { buffer = buf, silent = true })
end

return M
