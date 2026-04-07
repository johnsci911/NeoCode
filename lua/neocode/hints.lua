local M = {}

local _win = nil
local _buf = nil

local KEYMAP_LINES = {
  "  NeoCode",
  " ──────────────────────────────────────",
  "  <leader>aiC   New session / launcher",
  "  h             Resume session (native picker)",
  "  i             Multi-line input",
  "  <leader>p     Paste image",
  "  <C-c>         Interrupt AI",
  "  Q             Close session",
  "  { / }         Cycle sessions",
  "  <S-p>         Quick session picker",
  "  ?             Toggle this overlay",
  " ──────────────────────────────────────",
  "  MCP tools auto-detected via mcphub",
  " ──────────────────────────────────────",
  "  Press ? or q to dismiss",
}

function M._is_open()
  return _win ~= nil and vim.api.nvim_win_is_valid(_win)
end

function M._force_close()
  if _win and vim.api.nvim_win_is_valid(_win) then
    vim.api.nvim_win_close(_win, true)
  end
  _win = nil
  _buf = nil
end

function M.toggle()
  if M._is_open() then
    M._force_close()
    return
  end

  _buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(_buf, 0, -1, false, KEYMAP_LINES)
  vim.bo[_buf].modifiable = false

  local width  = math.max(44, vim.o.columns - 4)
  local height = #KEYMAP_LINES
  local row    = vim.o.lines - height - 3
  local col    = math.floor((vim.o.columns - width) / 2)

  _win = vim.api.nvim_open_win(_buf, true, {
    relative = "editor",
    row      = row,
    col      = col,
    width    = width,
    height   = height,
    style    = "minimal",
    border   = "rounded",
    zindex   = 50,
  })

  vim.wo[_win].winhl = "Normal:NormalFloat,FloatBorder:FloatBorder"

  vim.keymap.set("n", "<Esc>", M._force_close, { buffer = _buf, silent = true })
  vim.keymap.set("n", "q",     M._force_close, { buffer = _buf, silent = true })
  vim.keymap.set("n", "?",     M._force_close, { buffer = _buf, silent = true })

  vim.api.nvim_create_autocmd("WinLeave", {
    buffer   = _buf,
    once     = true,
    callback = M._force_close,
  })
end

return M
