# NeoCode

A simple Neovim plugin that wraps AI CLIs with additional features:

- **Visible multi-line input** — compose prompts in a floating editor, not a single terminal line
- **Paste images from clipboard** — send screenshots and diagrams straight to the AI
- **Native session keymaps** — open, resume, and manage CLI sessions without leaving Neovim
- **Session persistence** — save, resume, and manage conversation history

No fancy UI, just plain simple native AI CLI experience inside Neovim.

## Install

```lua
-- lazy.nvim
{
  "johnsci911/NeoCode",
  dependencies = { "nvim-lua/plenary.nvim", "nvim-telescope/telescope.nvim" },
  config = function()
    require("neocode").setup({
      default_adapter = "pi",
      adapters = {
        pi = require("neocode.adapters.pi"),
        opencode = require("neocode.adapters.opencode"),
      },
    })
  end,
}
```

### With Pi

Pi is a terminal-based AI assistant. NeoCode launches it as a Neovim terminal job and provides a floating multi-line input window for composing prompts.

```lua
require("neocode").setup({
  default_adapter = "pi",
  adapters = {
    pi = require("neocode.adapters.pi"),
  },
})
```

Pi supports passing `--name`, `--provider`, and `--model` arguments. NeoCode uses these to label sessions and configure the CLI.

### With OpenCode

OpenCode is a terminal-based AI coding assistant. NeoCode launches it in a Neovim split and provides the same floating multi-line input window.

```lua
require("neocode").setup({
  default_adapter = "opencode",
  adapters = {
    opencode = require("neocode.adapters.opencode"),
  },
})
```

OpenCode runs as its own terminal UI. NeoCode adds the floating input window (`i`) and sends the composed prompt into the OpenCode terminal session.

### Requirements

- Neovim >= 0.9
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) *(optional — falls back to `vim.ui.select`)*
- `pngpaste` (macOS) or `wl-paste` / `xclip` (Linux) for image paste
- [Pi](https://github.com/nteract/pidora) (`pi`) for Pi sessions
- [OpenCode](https://opencode.ai/) (`opencode`) for OpenCode sessions

## Features

### Session Management

- Auto-title sessions from first message
- Save and resume conversations across Neovim restarts
- `/rename <title>` command or `R` keymap — rename the current session
- `/session` command — open the session history picker with timestamps
- Multi-select delete (`<Tab>` to select, `d` to delete)
- Auto-switch to next session on close (`Q`)

## Keymaps

### Global

| Keymap | Action |
|--------|--------|
| `<leader>aiC` | Open launcher — pick a CLI and start a new session |
| `<leader>ait` | Toggle NeoCode window (show/hide) |

### Inside a chat session (normal mode)

| Keymap | Action |
|--------|--------|
| `i` | Open the multi-line input window |
| `<M-n>r` | Rename current session |
| `<C-p>` | Paste image from clipboard |
| `<M-n>c` | Interrupt the AI |
| `<M-n>q` | Close session (switches to next if available) |
| `{` / `}` | Cycle between open sessions |
| `<S-p>` | Quick session picker |
| `H` | Toggle window (hide/show) |
| `?` | Toggle hint overlay |

Legacy normal-mode shortcuts `R`, `<C-c>`, and `Q` remain available. In terminal-mode CLI sessions, `<M-n>c`, `<M-n>q`, and `<M-n>r` work without first pressing `<C-\><C-n>`.

### Multi-line input window

| Keymap | Action |
|--------|--------|
| `<C-s>` | Send and close |
| `<C-CR>` | Send and close (Ctrl+Enter, when supported by your terminal) |
| `<M-CR>` | Send and close (Alt+Enter) |
| `<Esc>` | Cancel without sending |

### Slash commands (type in input window)

| Command | Action |
|---------|--------|
| `/session` | Open session history picker (resume/delete/rename) |
| `/rename <title>` | Rename current session |

### Session picker (`/session`)

| Keymap | Action |
|--------|--------|
| `<CR>` | Resume selected session |
| `<Tab>` | Multi-select |
| `d` | Delete selected session(s) |
| `r` | Rename session |
| `n` | New session |
| `<Esc>` | Cancel |

## Configuration

```lua
require("neocode").setup({
  default_adapter    = "pi",
  keymap_prefix      = "<leader>ai",
  data_dir           = vim.fn.stdpath("data") .. "/neocode",
  telescope_fallback = true,
  winbar             = "  ? help  /session history  i input  <M-n>r rename  <M-n>c stop  <M-n>q close  <C-p> image  H toggle  { } cycle\n",
  adapters = {
    pi = require("neocode.adapters.pi"),
    opencode = require("neocode.adapters.opencode"),
  },
})
```

### Pi adapter options

```lua
require("neocode").setup({
  adapters = {
    pi = require("neocode.adapters.pi"),
  },
})
```

The Pi adapter passes `--name`, `--provider`, and `--model` arguments to the `pi` CLI. These are set automatically based on session metadata.

### OpenCode adapter options

```lua
require("neocode").setup({
  adapters = {
    opencode = require("neocode.adapters.opencode"),
  },
})
```

The OpenCode adapter launches `opencode` by default and uses `--continue` for resuming sessions.

## Adding a CLI Adapter

Drop a file in `lua/neocode/adapters/` implementing this interface:

```lua
local M = {}

M.name          = "myai"
M.session_store = false  -- set true to persist sessions to disk

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

-- (Optional) Native session picker — used when /session resumes a CLI session
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

NeoCode wraps AI CLIs as Neovim terminal jobs. Each adapter spawns its CLI in a split window, manages the session lifecycle, and provides a floating multi-line input window for composing prompts.

Images are saved to a temp file under `data_dir/images/`, sent to the CLI via `chansend`, and cleaned up when the session closes.
