# NeoCode

A simple Neovim plugin that wraps AI CLIs with additional features:

- **Visible multi-line input** — compose prompts in a floating editor, not a single terminal line
- **Paste images from clipboard** — send screenshots and diagrams straight to the AI
- **Native session keymaps** — open, resume, and manage CLI sessions without leaving Neovim

No fancy UI, just plain simple native AI CLI experience inside Neovim.

## Install

```lua
-- lazy.nvim
{
  "johnsci911/NeoCode",
  dependencies = { "nvim-lua/plenary.nvim", "nvim-telescope/telescope.nvim" },
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

### Requirements

- Neovim >= 0.9
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) *(optional — falls back to `vim.ui.select`)*
- `pngpaste` (macOS) or `wl-paste` / `xclip` (Linux) for image paste

## Keymaps

### Global

| Keymap | Action |
|--------|--------|
| `<leader>aic` | Open launcher — pick a CLI and start a new session |
| `<leader>ait` | Toggle NeoCode window (show/hide) |

### Inside a chat session (normal mode)

| Keymap | Action |
|--------|--------|
| `i` | Open multi-line input window |
| `h` | Open the CLI's native session picker |
| `<leader>p` | Paste image from clipboard |
| `<C-c>` | Interrupt the AI |
| `{` / `}` | Cycle between open windows |
| `<S-p>` | Window picker |
| `H` | Toggle window (hide/show) |
| `?` | Toggle hint overlay |

> **Tip:** Press `<C-\><C-n>` to leave terminal mode first.

### Multi-line input window

| Keymap | Action |
|--------|--------|
| `<C-s>` | Send and close |
| `<M-CR>` | Send and close (Alt+Enter) |
| `<Esc>` | Cancel without sending |

### Session picker (`h`)

| Keymap | Action |
|--------|--------|
| `<CR>` | Open selected session |
| `<Esc>` | Cancel |

## Configuration

```lua
require("neocode").setup({
  default_adapter    = "claude",
  keymap_prefix      = "<leader>ai",
  data_dir           = vim.fn.stdpath("data") .. "/neocode",
  telescope_fallback = true,
  winbar             = "  ? help  h resume  i input  <leader>p image  <C-c> stop  { } cycle\n",
  adapters = {
    claude = require("neocode.adapters.claude"),
  },
})
```

| Option | Default | Description |
|--------|---------|-------------|
| `default_adapter` | `"claude"` | Adapter used by default |
| `keymap_prefix` | `"<leader>ai"` | Prefix for global keymaps |
| `data_dir` | `stdpath("data")/neocode` | Where temp images are stored |
| `telescope_fallback` | `true` | Use `vim.ui.select` if Telescope is not available |
| `winbar` | *(hint string)* | Persistent keymap hint shown at the top of each chat window |
| `adapters` | `{}` | Table of adapter name → adapter module |

## Adding a CLI Adapter

Drop a file in `lua/neocode/adapters/` implementing this interface:

```lua
local M = {}

M.name          = "myai"
M.session_store = true  -- set false to skip persisting sessions to disk

-- (Required) Launch a new session
function M.launch_cmd(opts)
  return { cmd = "myai", args = { "--name", opts.name }, cwd = opts.cwd }
end

-- (Required) Interrupt a running response
function M.interrupt(session)
  vim.fn.chansend(session.job_id, "\x03")
end

-- (Required) Send an image path to the CLI
function M.attach_image(session, path)
  vim.fn.chansend(session.job_id, path .. "\n")
end

-- (Optional) Native session picker — powers the `h` keymap
function M.resume_cmd(opts)
  return { cmd = "myai", args = { "--resume" }, cwd = opts.cwd }
end

return M
```

Register it in `setup()`:

```lua
require("neocode").setup({
  adapters = {
    myai = require("neocode.adapters.myai"),
  },
})
```

## How it works

NeoCode spawns each AI CLI as a Neovim terminal job (`vim.fn.termopen`) in a vertical split. The CLI owns its own rendering and session history — NeoCode only manages the window lifecycle and keymaps. Every native CLI feature (streaming, slash commands, shortcuts, history) works without any special handling.

Images are saved to a temp file under `data_dir/images/`, sent to the CLI, and cleaned up when the session closes.

## TODO

- [ ] Customizable keymaps
- [ ] Enable/disable adapters per config
- [ ] Support for custom credentials per adapter
- [ ] Auto-install configured CLI if not found
