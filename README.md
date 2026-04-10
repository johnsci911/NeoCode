# NeoCode

A simple Neovim plugin that wraps AI CLIs with additional features:

- **Visible multi-line input** — compose prompts in a floating editor, not a single terminal line
- **Paste images from clipboard** — send screenshots and diagrams straight to the AI
- **Native session keymaps** — open, resume, and manage CLI sessions without leaving Neovim
- **Local LLM support** — chat with local models via llama-server (llama.cpp)
- **MCP tool calling** — read files, search code, execute commands via mcphub.nvim
- **Web search** — auto-detect queries and search DuckDuckGo for current info
- **Project context** — auto-reads .neocode.md, CLAUDE.md, .cursorrules, README.md, and more
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
      default_adapter = "claude",
      adapters = {
        claude = require("neocode.adapters.claude"),
      },
    })
  end,
}
```

### With Local LLM (llama.cpp)

```lua
{
  "johnsci911/NeoCode",
  dependencies = { "nvim-lua/plenary.nvim", "nvim-telescope/telescope.nvim" },
  config = function()
    local llama = require("neocode.adapters.llama")
    llama.setup({
      base_url = "http://localhost:8080",
    })
    require("neocode").setup({
      default_adapter = "claude",
      adapters = {
        claude = require("neocode.adapters.claude"),
        llama = llama,
      },
    })
  end,
}
```

Start llama-server:

```bash
llama-server --hf-repo <model-repo> -ngl 99 -c 32768 --host 0.0.0.0 --port 8080
```

#### Tested model

```bash
llama-server \
  --hf-repo Jackrong/Qwen3.5-9B-Claude-4.6-Opus-Reasoning-Distilled-v2-GGUF \
  --hf-file Qwen3.5-9B.Q8_0.gguf \
  -ngl 99 -c 32768 --host 0.0.0.0 --port 8080 \
  --temp 0.6 --top-p 0.85 --top-k 30 --min-p 0.05 --repeat-penalty 1.1
```

> This model has vision built-in -- no separate `--mmproj` needed.

#### AMD GPU (Vulkan) note

If you're on AMD with Vulkan (e.g. RX 6900 XT via MoltenVK on macOS), use llama.cpp build **b6241** for stable Vulkan support. Newer builds may have Vulkan regressions.

```bash
cd llama.cpp
git checkout b6241
cmake -B build && cmake --build build --config Release
```

#### Other recommended models

| Model | Size | VRAM | Vision | Tool Calling | Notes |
|-------|------|------|--------|-------------|-------|
| Qwen3.5-9B-Claude-Distilled (Q8) | 9B | ~9GB | Yes | Generic | Tested, works with vision |
| Qwen3-14B | 14B | ~9GB (Q4) | No | Native | Strong coding + tools |
| Qwen3-Coder-30B-A3B (MoE) | 30B/3B active | ~14GB (Q3) | No | Native | Best coder, needs `--jinja` + newer build |
| Qwen3-VL-8B-Thinking | 8B | ~7GB (Q4) | Yes | Generic | Best vision + thinking |
| Devstral Vision Small 2507 | 24B | ~14GB (Q4) | Yes | Yes | Coding + vision + tools, tight fit |

### With MCP Tools (mcphub.nvim)

Add [mcphub.nvim](https://github.com/ravitemer/mcphub.nvim) to your plugins and NeoCode auto-detects it:

```lua
{
  "ravitemer/mcphub.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  build = "npm install -g mcp-hub@latest",
  config = function()
    require("mcphub").setup()
  end,
}
```

Configure MCP servers in `~/.config/mcphub/servers.json`:

```json
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/allowed/dir"]
    },
    "fetch": {
      "command": "npx",
      "args": ["-y", "@anthropic/mcp-server-fetch"]
    }
  }
}
```

### Requirements

- Neovim >= 0.9
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) *(optional — falls back to `vim.ui.select`)*
- [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim) *(optional — renders chat with proper markdown)*
- `pngpaste` (macOS) or `wl-paste` / `xclip` (Linux) for image paste
- [llama.cpp](https://github.com/ggml-org/llama.cpp) for local LLM support
- [mcphub.nvim](https://github.com/ravitemer/mcphub.nvim) for MCP tool calling *(optional)*

## Features

### Local LLM via llama-server

- Auto-detect model name from running server
- Streaming responses with live t/s and context usage
- Thinking content displayed as blockquotes
- Degenerate output detection (stops gibberish)
- Auto-continue truncated responses (up to 3 retries)
- Connection failure detection with helpful error messages

### MCP Tool Calling

- Auto-detects mcphub.nvim and available MCP servers
- Claude Code-style permission system (Allow once / session / always / deny)
- Tool call display with result previews (first 6 lines shown)
- Action-aware icons: 📖 read, ✏️ write, ⚡ execute, 📄 resource, 📋 prompt
- Agentic loop: model calls tools, gets results, calls more tools, gives final answer
- Parses structured tool_calls, `<tool_call>` XML, and bare JSON formats
- Path resolution: relative paths and hallucinated `/home/user/` paths auto-fixed

### Project Context

Auto-reads project instruction files and injects into the system prompt:

| File | Source |
|------|--------|
| `.neocode.md` | NeoCode |
| `CLAUDE.md`, `.claude/instructions.md` | Claude Code |
| `.cursorrules`, `.cursor/rules/project.mdc` | Cursor |
| `.github/copilot-instructions.md` | GitHub Copilot |
| `.windsurfrules` | Windsurf |
| `.clinerules` | Cline |
| `AGENTS.md` | Codex |
| `GEMINI.md` | Gemini |
| `.ai-instructions.md`, `AI.md` | Generic |
| `README.md` | Any project |
| `.neocode/skills/*.md` | Custom skills |

When no instruction files exist, auto-detects:
- Languages and frameworks from package files (package.json, composer.json, Cargo.toml, etc.)
- Project structure (2 levels deep)
- Package metadata (name, description, scripts)

### Web Search

- Auto-detects queries needing current info (keywords: "latest", "news", "2025", etc.)
- DuckDuckGo search via Python `ddgs` package (auto-installs)
- `@web` prefix forces a search
- Results injected as context for the model

### Session Management

- Auto-title sessions from first message
- Save and resume conversations across Neovim restarts
- `/compact` command — summarize conversation to free context
- Session history picker with timestamps (`h` keymap)
- Multi-select delete (`<Tab>` to select, `d` to delete)
- Auto-switch to next session on close (`Q`)

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
| `h` | Session history picker (resume/delete/rename) |
| `<leader>p` | Paste image from clipboard |
| `<C-c>` | Interrupt the AI |
| `Q` | Close session (switches to next if available) |
| `{` / `}` | Cycle between open sessions |
| `<S-p>` | Quick session picker |
| `H` | Toggle window (hide/show) |
| `?` | Toggle hint overlay |

> **Tip:** Press `<C-\><C-n>` to leave terminal mode first.

### Multi-line input window

| Keymap | Action |
|--------|--------|
| `<C-s>` | Send and close |
| `<M-CR>` | Send and close (Alt+Enter) |
| `<Esc>` | Cancel without sending |

### Slash commands (type in input window)

| Command | Action |
|---------|--------|
| `/compact` | Summarize conversation to free context |

### Session picker (`h`)

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
  default_adapter    = "claude",
  keymap_prefix      = "<leader>ai",
  data_dir           = vim.fn.stdpath("data") .. "/neocode",
  telescope_fallback = true,
  winbar             = "  ? help  h resume  i input  <leader>p image  <C-c> stop  H toggle  { } cycle\n",
  adapters = {
    claude = require("neocode.adapters.claude"),
  },
})
```

### Llama adapter options

```lua
local llama = require("neocode.adapters.llama")
llama.setup({
  base_url       = "http://localhost:8080",  -- llama-server URL
  temperature    = 0.6,    -- creativity (0.0-2.0)
  top_p          = 0.85,   -- nucleus sampling
  repeat_penalty = 1.1,    -- repetition penalty
  max_tokens     = 16384,  -- max output tokens
  max_messages   = 30,     -- conversation history limit
  context_size   = 32768,  -- for context usage display
})
```

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

NeoCode supports two adapter types:

**CLI adapters** (Claude, OpenCode) spawn each AI CLI as a Neovim terminal job. The CLI owns its own rendering and session history — NeoCode only manages the window lifecycle and keymaps.

**API adapters** (Llama) communicate with a local LLM server via the OpenAI-compatible API. NeoCode handles message management, streaming, tool calling, and rendering in a markdown buffer.

MCP tools are auto-detected from mcphub.nvim when available. The model can call tools to read files, search code, list directories, and execute commands. A permission system (Allow once / session / always) controls tool access.

Images are saved to a temp file under `data_dir/images/`, sent to the CLI or API, and cleaned up when the session closes.
