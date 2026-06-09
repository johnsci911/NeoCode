# NeoCode

A simple Neovim plugin that wraps AI CLIs with additional features:

- **Visible multi-line input** — compose prompts in a floating editor, not a single terminal line
- **Paste images from clipboard** — send screenshots and diagrams straight to the AI
- **Native session keymaps** — open, resume, and manage CLI sessions without leaving Neovim
- **Local LLM support** — use NeoCode Local for OpenAI-compatible local servers, or launch Continue CLI as a fallback
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

Continue remains available as the legacy/fallback local CLI path. It owns its own model configuration, tools, and history.

```lua
{
  "johnsci911/NeoCode",
  dependencies = { "nvim-lua/plenary.nvim", "nvim-telescope/telescope.nvim" },
  config = function()
    local llama = require("neocode.adapters.llama")
    llama.setup({
      command = "cn",
      -- Optional: generate Continue config from llama-server before launching.
      dynamic_continue_config = {
        enabled = true,
        llama_server = "http://127.0.0.1:8080",
        max_tokens = 3500,
      },
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

By default, configure your running local LLM in Continue, not NeoCode. For an OpenAI-compatible local server such as `llama-server`, use `~/.continue/config.yaml`:

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

With the default llama adapter settings, NeoCode only opens the Continue terminal session. Continue handles model selection, roles, prompts, tools, completion options, and provider details.

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

Continue CLI owns its live chat history, so NeoCode cannot reliably rewrite or compact a running Continue session from the outside. Llama/Continue sessions are not persisted in NeoCode's session store; use Continue's history/resume flow instead.

Alternatively, enable `dynamic_continue_config` to let NeoCode generate that Continue config at launch time from a running `llama-server`. NeoCode reads `/props` and `/v1/models`, writes a generated config to `stdpath("data") .. "/neocode/continue.generated.yaml"`, then launches `cn --config <generated-file>`:

```lua
llama.setup({
  command = "cn",
  dynamic_continue_config = {
    enabled = true,
    llama_server = "http://127.0.0.1:8080",
    max_tokens = 3500,
  },
})
```

The generated config uses the server's runtime context (`n_ctx`, for example `24576`) rather than the model's training context (`n_ctx_train`). If probing fails because `llama-server` is not running, NeoCode falls back to the adapter's configured `args`. When generation succeeds, NeoCode preserves other Continue CLI args and replaces only an existing `--config` argument with the generated config path.

Resume also goes through Continue CLI. Choosing a closed Llama/Continue session from `/session` launches `cn --resume`; if `dynamic_continue_config` is enabled, NeoCode first regenerates the config and resumes with `cn --resume --config <generated-file>`.

### With NeoCode Local

`NeoCode Local` is NeoCode's first-party API-backed local adapter. It talks directly to an OpenAI-compatible endpoint and lets NeoCode own the chat buffer, session history, local tools, usage stats, and compaction.

```lua
{
  "johnsci911/NeoCode",
  dependencies = { "nvim-lua/plenary.nvim", "nvim-telescope/telescope.nvim" },
  config = function()
    local local_adapter = require("neocode.adapters.local")
    local_adapter.setup({
      provider = "llama_server", -- or "openai_compatible"
      base_url = "http://127.0.0.1:8080/v1",
    })

    require("neocode").setup({
      default_adapter = "local",
      adapters = {
        ["local"] = local_adapter,
        claude = require("neocode.adapters.claude"),
      },
    })
  end,
}
```

For `llama-server`, NeoCode Local probes `/props` and `/v1/models` to populate the active model name and runtime context window. For generic OpenAI-compatible servers, it probes `/v1/models` and falls back to the configured context size when the server does not expose one.

Optional configuration:

```lua
local_adapter.setup({
  provider = "openai_compatible",
  base_url = "http://127.0.0.1:1234/v1",
  model = "local-model",       -- fallback if probing cannot detect one
  context_size = 32768,         -- fallback if metadata is unavailable
  temperature = 0.2,
  max_tokens = 4096,
})
```

NeoCode Local uses NeoCode-managed API sessions, so `/compact`, history resume, native project tools, and web-search tool routing work through NeoCode rather than Continue.

NeoCode Local can expose workspace tools to the model:

- read files
- list directories
- search files
- run shell commands

Shell commands use a small safe-command allowlist. Other commands pause for a per-session approval prompt with `Allow once`, `Allow and don't ask again`, `No`, and `Continue prompting`. Likely interactive commands such as `vim`, `nvim`, `less`, `top`, `ssh`, `python`, and `node` REPL sessions are blocked instead of being sent blindly to the terminal.

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
- A local OpenAI-compatible model server for NeoCode Local, such as `llama-server`
- [Continue CLI](https://docs.continue.dev/cli/) (`cn`) for the legacy/fallback local CLI path
- [OpenCode](https://opencode.ai/) (`opencode`) for OpenCode sessions

## Features

### NeoCode Local and Continue CLI

- `NeoCode Local` talks directly to OpenAI-compatible local servers through NeoCode's API session flow
- `NeoCode Local` probes model/context metadata when available and keeps local tools/session history inside NeoCode
- `Llama (Continue)` launches Continue CLI (`cn`) in a NeoCode terminal session
- Continue remains useful as a fallback when you want Continue to own local model configuration and history

### Local LLM via Continue CLI

- `Llama (Continue)` launches Continue CLI (`cn`) in a NeoCode terminal session
- Continue owns local model configuration through `~/.continue/config.yaml` by default
- Continue owns local chat history; NeoCode resumes via `cn --resume` instead of saving Llama sessions itself
- Optional `dynamic_continue_config` can generate model/provider/context settings from a running llama-server before launching Continue

### Local Tool Calling

NeoCode API sessions can expose native workspace tools for project prompts:

- `neocode__read_file` — read one text file inside the workspace
- `neocode__list_directory` — list files in a workspace directory
- `neocode__search_files` — search workspace text files
- `neocode__run_shell_command` — run approved shell commands in the workspace

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
- `/session` command — open the session history picker with timestamps
- Multi-select delete (`<Tab>` to select, `d` to delete)
- Auto-switch to next session on close (`Q`)

### Memory and Skills

NeoCode Local stores project-scoped memory in NeoCode's data directory, not inside the project repository.

Use explicit slash commands from a NeoCode API session:

| Command | Action |
|---------|--------|
| `/memory save <text>` | Save a project-scoped memory entry under `stdpath("data")/neocode/memory/projects/` |
| `/skill save <name> <instructions>` | Save a reusable skill under `stdpath("data")/neocode/skills/` |
| `/skill select <name>[,name...]` | Manually select skills to inject into future turns for the current runtime config |

Memory and selected skills are injected as system context for NeoCode-managed API sessions. NeoCode does not write `.neocode/memory.md` or generated skill files into the project tree by default.

## Keymaps

### Global

| Keymap | Action |
|--------|--------|
| `<leader>aic` | Open launcher — pick a CLI and start a new session |
| `<leader>ait` | Toggle NeoCode window (show/hide) |

### Inside a chat session (normal mode)

| Keymap | Action |
|--------|--------|
| `i` | Insert in NeoCode Local's inline draft, or open the multi-line input window when inline editing is unavailable |
| `R` | Rename current session |
| `<C-p>` | Paste image from clipboard |
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
| `<C-CR>` | Send and close (Ctrl+Enter, when supported by your terminal) |
| `<M-CR>` | Send and close (Alt+Enter) |
| `<Esc>` | Cancel without sending |

### Slash commands (type in input window)

| Command | Action |
|---------|--------|
| `/compact` | Summarize NeoCode-managed API conversations to free context |
| `/session` | Open session history picker (resume/delete/rename) |
| `/thinking [off\|low\|medium\|high\|max]` | Open an interactive thinking selector, or set llama.cpp thinking controls directly when the active server reports support |
| `/rename <title>` | Rename current session |
| `/readfile <path>` | Read an exact local file without web search |
| `/websearch <query>` | Force web search for current/external information |
| `/memory save <text>` | Save project memory in NeoCode's data directory |
| `/skill save <name> <instructions>` | Save a reusable skill in NeoCode's data directory |
| `/skill select <name>[,name...]` | Manually select skills for future turns |

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
  default_adapter    = "claude",
  keymap_prefix      = "<leader>ai",
  data_dir           = vim.fn.stdpath("data") .. "/neocode",
  telescope_fallback = true,
  winbar             = "  ? help  /session history  i input  R rename  <C-p> image  <C-c> stop  H toggle  { } cycle\n",
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
  dynamic_continue_config = {
    enabled = false,
    llama_server = "http://127.0.0.1:8080",
    output = nil, -- defaults to stdpath("data") .. "/neocode/continue.generated.yaml"
    max_tokens = 3500,
  },
})
```

Put model/provider settings in Continue's config, or enable `dynamic_continue_config` to generate them from a running llama-server at launch time.

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

NeoCode supports two adapter types:

**CLI adapters** (Claude, OpenCode, Llama/Continue) spawn each AI CLI as a Neovim terminal job. The CLI owns its own rendering and session history — NeoCode only manages the window lifecycle and keymaps.

**API adapters** communicate with model APIs directly. NeoCode handles message management, streaming, local tool calling, and rendering in a markdown buffer.

API adapter project prompts expose NeoCode's native read/list/search tools. Web search is exposed only for explicit or current-info prompts. Continue CLI sessions own their own tool setup through Continue config.

Images are saved to a temp file under `data_dir/images/`, sent to the CLI or API, and cleaned up when the session closes.
