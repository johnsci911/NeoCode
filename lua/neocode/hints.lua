local M = {}

local _win = nil
local _buf = nil

local KEYMAP_LINES = {
  "  NeoCode",
  " ──────────────────────────────────────",
  "  <leader>aiC   New session",
  "  <S-p>         Session picker",
  "  <leader>p     Paste image",
  "  <C-c>         Interrupt AI",
  "  { / }         Cycle sessions",
  "  <leader>ai    Toggle this overlay",
  " ──────────────────────────────────────",
  "  Press any key to dismiss",
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

function M.toggle(_config)
  if M._is_open() then
    M._force_close()
    return
  end

  -- Create buffer
  _buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(_buf, 0, -1, false, KEYMAP_LINES)
  vim.bo[_buf].modifiable = false

  -- Calculate position: bottom of editor
  local width  = math.max(44, vim.o.columns - 4)
  local height = #KEYMAP_LINES
  local row    = vim.o.lines - height - 3
  local col    = math.floor((vim.o.columns - width) / 2)

  _win = vim.api.nvim_open_win(_buf, false, {
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

  -- Close on keypress
  vim.keymap.set("n", "<Esc>", M._force_close, { buffer = _buf, silent = true })
  vim.keymap.set("n", "q",     M._force_close, { buffer = _buf, silent = true })

  -- Auto-close when focus leaves
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer   = _buf,
    once     = true,
    callback = M._force_close,
  })
end

return M
