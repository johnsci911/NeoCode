# neocode.nvim

A Neovim plugin that wraps AI CLIs — starting with [Claude Code](https://docs.anthropic.com/en/docs/claude-code) — with native Neovim UX. Image paste, multi-line input, and a hint overlay. No API keys. No re-implementation of the AI layer. The CLI does its thing; NeoCode makes it feel at home in Neovim.

## Features

- **Native terminal sessions** — the CLI renders in a vertical split terminal buffer. All CLI features work as-is: slash commands (`/btw`, `/compact`, `/fork`, etc.), keyboard shortcuts, and history — handled entirely by the CLI
- **Multi-line input** — compose long prompts in a floating editor window (`i`), send with `<C-s>`
- **Image paste** — grab an image from clipboard with `<leader>p`; temp file is created, sent to the CLI, and cleaned up automatically
- **Hint overlay** — press `?` for a which-key style cheatsheet anchored to the bottom of the screen
- **Adapter pattern** — swap or add CLI backends by dropping a file in `adapters/`

## Requirements

- Neovim ≥ 0.9
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) *(optional — falls back to `vim.ui.select`)*
- `pngpaste` (macOS) or `wl-paste` / `xclip` (Linux) for image paste

## Install

```lua
-- lazy.nvim
{
  "yourname/neocode.nvim",
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

## Keymaps

### Global

| Keymap | Action |
|--------|--------|
| `<leader>aiC` | Open launcher — pick a CLI and start a new session |

### Inside a chat session (normal mode)

| Keymap | Action |
|--------|--------|
| `i` | Open multi-line input window |
| `h` | Open the CLI's native session picker |
| `<leader>p` | Paste image from clipboard |
| `<C-c>` | Interrupt the AI (normal and terminal mode) |
| `{` / `}` | Cycle between open windows |
| `<S-p>` | Window picker |
| `?` | Toggle hint overlay |

> **Tip:** Most keymaps work in normal mode. Press `<C-\><C-n>` to leave terminal mode.

### Multi-line input window

| Keymap | Action |
|--------|--------|
| `<C-s>` | Send and close |
| `<M-CR>` | Send and close (Alt+Enter fallback) |
| `<Esc>` | Cancel without sending |

### CLI session picker (`h`)

| Keymap | Action |
|--------|--------|
| `<CR>` | Open selected session |
| `<Esc>` | Cancel and return to current window |

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
M.session_store = true  -- set false to skip persisting this adapter's sessions to disk

-- (Required) Return the command spec to launch a new session
function M.launch_cmd(opts)
  -- opts: { cwd, name }
  return { cmd = "myai", args = { "--name", opts.name }, cwd = opts.cwd }
end

-- (Required) Send Ctrl-C to interrupt a running response
function M.interrupt(session)
  vim.fn.chansend(session.job_id, "\x03")
end

-- (Required) Send an image path to the CLI input
function M.attach_image(session, path)
  vim.fn.chansend(session.job_id, path .. "\n")
end

-- (Optional) Return the command spec for the CLI's native session picker.
-- If provided, the `h` keymap will open it. If omitted, `h` shows a warning.
function M.resume_cmd(opts)
  -- opts: { cwd }
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

NeoCode spawns each AI CLI as a Neovim terminal job (`vim.fn.termopen`) in a vertical split. The CLI owns its own rendering and session history — NeoCode only manages the window lifecycle and convenience keymaps. Every native CLI feature (streaming output, slash commands, keyboard shortcuts, session history) works without any special handling.

Images are saved to a temp file under `data_dir/images/`, sent to the CLI, and deleted when the session closes or on the next startup if the session crashed.
