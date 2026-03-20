# neocode.nvim

Neovim wrapper for AI CLIs — brings image paste, multi-session management, and a hint overlay to Claude Code and friends.

## Features

- **Terminal buffer sessions** — native CLI renders inside a Neovim vertical split; you keep all CLI features including slash commands (`/btw`, `/effort`, `/compact`, etc.)
- **Image paste** from clipboard (`<leader>p`) and drag & drop — temp files auto-deleted after send
- **Multi-session** with `{`/`}` cycling and a Telescope session picker
- **Which-key style hint overlay** (`<leader>ai`) — toggleable, anchored to bottom
- **Adapter pattern** — add new CLIs by dropping a file in `adapters/`; OpenCode support planned

## Requirements

- Neovim ≥ 0.9
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) *(optional — falls back to `vim.ui.select`)*
- `pngpaste` (macOS) or `wl-paste`/`xclip` (Linux) for image paste

## Install

```lua
-- lazy.nvim
{
  "yourname/neocode.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  config = function()
    require("neocode").setup({
      default_adapter = "claude",
      adapters = {
        claude = require("neocode.adapters.claude"),
      },
    })
  end,
}
```

## Keymaps

| Keymap | Context | Action |
|--------|---------|--------|
| `<leader>aiC` | Global | New session |
| `<leader>ai` | Global | Toggle hint overlay |
| `<leader>p` | In chat | Paste image from clipboard |
| `<S-p>` | In chat (normal mode) | Session picker |
| `<C-c>` | In chat | Interrupt AI |
| `{` / `}` | In chat (normal mode) | Cycle sessions |

> **Note:** `{`, `}`, `<S-p>` work in normal mode. Press `<C-\><C-n>` to leave terminal mode first.

## Configuration

```lua
require("neocode").setup({
  default_adapter    = "claude",           -- adapter to use for new sessions
  keymap_prefix      = "<leader>ai",       -- prefix for global keymaps
  data_dir           = vim.fn.stdpath("data") .. "/neocode",  -- sessions + images
  telescope_fallback = true,               -- fall back to vim.ui.select if Telescope absent
  adapters = {
    claude = require("neocode.adapters.claude"),
  },
})
```

## Adding a New CLI Adapter

Drop a file in `lua/neocode/adapters/`:

```lua
-- lua/neocode/adapters/myai.lua
local M = {}

M.name          = "myai"
M.session_store = true  -- false if the CLI manages sessions natively

function M.launch_cmd(opts)
  return { cmd = "myai", args = {}, env = nil, cwd = opts.cwd }
end

function M.interrupt(session)
  vim.fn.chansend(session.job_id, "\x03")
end

function M.attach_image(session, path)
  vim.fn.chansend(session.job_id, path .. "\n")
end

return M
```

Then register it in `setup()`:
```lua
require("neocode").setup({
  adapters = {
    myai = require("neocode.adapters.myai"),
  },
})
```
