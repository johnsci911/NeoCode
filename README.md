# NeoCode

A simple Neovim plugin that wraps AI CLIs with additional features:

- **Visible multi-line input** — compose prompts in a floating editor, not a single terminal line
- **Paste images from clipboard** — send screenshots and diagrams straight to the AI
- **Native session keymaps** — open, resume, and manage CLI sessions without leaving Neovim
- **Local LLM support** — launch Continue CLI for local models configured in Continue
- **Native local tools** — read files, list directories, and search code from NeoCode API sessions
- **Web search** — explicit/current-info DuckDuckGo search without hijacking local project prompts
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

### With Local LLM (Continue CLI)

```lua
{
  "johnsci911/NeoCode",
  dependencies = { "nvim-lua/plenary.nvim", "nvim-telescope/telescope.nvim" },
  config = function()
    local llama = require("neocode.adapters.llama")
    llama.setup({
      -- Optional: defaults to `cn`. Keep model/provider settings in Continue.
      command = "cn",
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

Configure your running local LLM in Continue, not NeoCode. For an OpenAI-compatible local server such as `llama-server`, use `~/.continue/config.yaml`:

```yaml
name: Local Llama
version: 1.0.0
schema: v1
models:
  - name: Local Llama
    provider: openai
    model: <your-model-id>
    apiBase: http://127.0.0.1:8080/v1
    roles:
      - chat
      - edit
      - apply
```

If you keep Continue config somewhere else, pass only Continue CLI arguments through NeoCode:

```lua
llama.setup({
  args = { "--config", vim.fn.expand("~/.continue/config.yaml") },
})
```

NeoCode only opens the Continue terminal session. Continue handles model selection, roles, prompts, tools, completion options, and provider details.

To make Continue compact around ~20k tokens on a llama-server running with a 24,576 token context, set Continue's own limits:

```yaml
models:
  - name: Local Llama
    provider: openai
    model: unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF
    apiBase: http://127.0.0.1:8080/v1
    defaultCompletionOptions:
      contextLength: 24576
      maxTokens: 3500
    roles:
      - chat
      - edit
      - apply
```

Continue CLI owns its live chat history, so NeoCode cannot reliably rewrite or compact a running Continue session from the outside.

### With OpenCode

```lua
{
  "johnsci911/NeoCode",
  dependencies = { "nvim-lua/plenary.nvim", "nvim-telescope/telescope.nvim" },
  config = function()
    require("neocode").setup({
      default_adapter = "claude",
      adapters = {
        claude = require("neocode.adapters.claude"),
        opencode = require("neocode.adapters.opencode"),
      },
    })
  end,
}
```

OpenCode runs as its own terminal UI. NeoCode adds the same floating multi-line input window (`i`) used by Claude CLI, then sends the composed prompt into the OpenCode terminal session.

### Requirements

- Neovim >= 0.9
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) *(optional — falls back to `vim.ui.select`)*
- [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim) *(optional — renders chat with proper markdown)*
- `pngpaste` (macOS) or `wl-paste` / `xclip` (Linux) for image paste
- [Continue CLI](https://docs.continue.dev/cli/) (`cn`) for local LLM support
- [OpenCode](https://opencode.ai/) (`opencode`) for OpenCode sessions

## Features

### Local LLM via Continue CLI

- `Llama (Local)` launches Continue CLI (`cn`) in a NeoCode terminal session
- Continue owns local model configuration through `~/.continue/config.yaml`
- NeoCode does not duplicate provider, prompt, tool, sampling, or role customization

### Local Tool Calling

NeoCode API sessions can expose three native workspace tools for project prompts:

- `neocode__read_file` — read one text file inside the workspace
- `neocode__list_directory` — list files in a workspace directory
- `neocode__search_files` — search workspace text files

NeoCode keeps web search separate from the local hot path:

- README/project/file prompts get local tools, not web search.
- `/websearch` and `@web` force web search.

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

- `/websearch` prefix forces a web search before the model responds
- For ordinary prompts, web search is exposed as a model-selectable tool only when the prompt looks like it may need current or external information
- DuckDuckGo search via Python `ddgs` package (auto-installs)
- `@web` prefix also forces a search
- Results injected as context for the model

### Session Management

- Auto-title sessions from first message
- Save and resume conversations across Neovim restarts
- `/compact` command — summarize NeoCode-managed API conversations to free context
- `/rename <title>` command or `R` keymap — rename the current session
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
| `R` | Rename current session |
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
| `/compact` | Summarize NeoCode-managed API conversations to free context |
| `/rename <title>` | Rename current session |
| `/readfile <path>` | Read an exact local file without web search |
| `/websearch <query>` | Force web search for current/external information |

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
  winbar             = "  ? help  h resume  i input  R rename  <leader>p image  <C-c> stop  H toggle  { } cycle\n",
  auto_compact       = {
    enabled = false, -- API sessions only; CLI adapters such as Continue own their own history
    threshold = 0.8, -- compact at 80% of context_size, e.g. ~20k/24.5k
    context_size = 24576,
    preserve_recent_turns = 4,
  },
  adapters = {
    claude = require("neocode.adapters.claude"),
  },
})
```

### Llama (Local) adapter options

```lua
local llama = require("neocode.adapters.llama")
llama.setup({
  command = "cn", -- Continue CLI executable
  args = {},      -- optional Continue CLI args, e.g. { "--config", "~/.continue/config.yaml" }
})
```

Put model/provider settings in Continue's config, not here.

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

**CLI adapters** (Claude, OpenCode, Llama/Continue) spawn each AI CLI as a Neovim terminal job. The CLI owns its own rendering and session history — NeoCode only manages the window lifecycle and keymaps.

**API adapters** communicate with model APIs directly. NeoCode handles message management, streaming, local tool calling, and rendering in a markdown buffer.

API adapter project prompts expose NeoCode's native read/list/search tools. Web search is exposed only for explicit or current-info prompts. Continue CLI sessions own their own tool setup through Continue config.

Images are saved to a temp file under `data_dir/images/`, sent to the CLI or API, and cleaned up when the session closes.
