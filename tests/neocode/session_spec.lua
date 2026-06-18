local session = require("neocode.session")

describe("session", function()
  before_each(function()
    session._reset()  -- clear in-memory state between tests
  end)

  describe("_needs_project_tools", function()
    it("does not enable project tools for casual chat", function()
      assert.is_false(session._needs_project_tools("Hi how are you?"))
      assert.is_false(session._needs_project_tools("thanks, that makes sense"))
    end)

    it("enables project tools for explicit file requests", function()
      assert.is_true(session._needs_project_tools("Can you read plan.md for me?"))
      assert.is_true(session._needs_project_tools("Open routes/web.php and explain it"))
      assert.is_true(session._needs_project_tools("Can you read the readme and tell me what this project is about?"))
    end)

    it("enables project tools for codebase and framework requests", function()
      assert.is_true(session._needs_project_tools("Review this codebase"))
      assert.is_true(session._needs_project_tools("Can you inspect my Laravel routes?"))
      assert.is_true(session._needs_project_tools("what is this project about?"))
    end)

    it("supports explicit chat and project overrides", function()
      assert.is_false(session._needs_project_tools("@chat read plan.md"))
      assert.is_true(session._needs_project_tools("@project hello"))
      assert.is_true(session._needs_project_tools("/readfile README.md"))
    end)
  end)

  describe("MCP removal", function()
    it("does not treat MCP prefixes as project tool requests", function()
      assert.is_false(session._needs_project_tools("@mcp use the github server"))
      assert.is_false(session._needs_project_tools("/mcp list available servers"))
    end)

    it("does not build tools for MCP-only prompts", function()
      assert.is_nil(session._build_project_tools("@mcp use the github server", "/project"))
      assert.is_nil(session._build_project_tools("/mcp list available servers", "/project"))
    end)
  end)

  describe("_build_project_tools", function()
    it("selects native local tools for project prompts without MCP", function()
      local tools = session._build_project_tools("Review this project", "/project")
      local names = {}
      for _, schema in ipairs(tools or {}) do
        table.insert(names, schema["function"].name)
      end

      assert.same({ "neocode__read_file", "neocode__list_directory", "neocode__search_files", "neocode__write_file", "neocode__run_shell_command" }, names)
    end)

    it("offers web search as a model-chosen tool for current-info prompts", function()
      local tools = session._build_project_tools("what is the weather today?", "/project")
      assert.equals("neocode__web_search", tools[1]["function"].name)
    end)

    it("does not replace local README reads with web-only tools", function()
      local tools = session._build_project_tools("read the readme and tell me what is this project about", "/project")
      local names = {}
      for _, schema in ipairs(tools or {}) do
        table.insert(names, schema["function"].name)
      end

      assert.same({ "neocode__read_file", "neocode__list_directory", "neocode__search_files", "neocode__write_file", "neocode__run_shell_command" }, names)
    end)

    it("keeps README update prompts on local tools", function()
      local tools = session._build_project_tools("update the README with setup notes", "/project")
      local names = {}
      for _, schema in ipairs(tools or {}) do
        table.insert(names, schema["function"].name)
      end

      assert.same({ "neocode__read_file", "neocode__list_directory", "neocode__search_files", "neocode__write_file", "neocode__run_shell_command" }, names)
    end)
  end)

  describe("tool permissions", function()
    it("builds stable shell permission keys per command", function()
      local key = session._tool_permission_key({
        ["function"] = {
          name = "neocode__run_shell_command",
          arguments = vim.fn.json_encode({ command = "echo hello" }),
        },
      })

      assert.equals("neocode__run_shell_command:echo hello", key)
    end)

    it("remembers allow-and-dont-ask-again decisions on the session record", function()
      local old_select = vim.ui.select
      vim.ui.select = function(_, _, cb) cb("Allow and don't ask again") end
      local record = {}
      local allowed = nil
      local tool_call = {
        ["function"] = {
          name = "neocode__run_shell_command",
          arguments = vim.fn.json_encode({ command = "echo hello" }),
        },
      }

      session._request_tool_permission(record, tool_call, function(value) allowed = value end)

      vim.ui.select = old_select
      assert.is_true(allowed)
      assert.is_true(record.tool_permissions["neocode__run_shell_command:echo hello"])
    end)

    it("persists allow-and-dont-ask-again decisions in layered session state", function()
      local tmp = vim.fn.tempname()
      vim.fn.mkdir(tmp, "p")
      local old_select = vim.ui.select
      vim.ui.select = function(_, _, cb) cb("Allow and don't ask again") end
      local record = {
        id = "permission-session",
        cwd = "/tmp/project-root",
      }
      local config = { data_dir = tmp }
      local tool_call = {
        ["function"] = {
          name = "neocode__run_shell_command",
          arguments = vim.fn.json_encode({ command = "echo hello" }),
        },
      }

      local ok, err = pcall(function()
        session._request_tool_permission(record, tool_call, function() end, config)
        local state = session._load_api_state(config, record)
        assert.is_true(state.tool_permissions["neocode__run_shell_command:echo hello"])
      end)

      vim.ui.select = old_select
      vim.fn.delete(tmp, "rf")
      assert.is_true(ok, err)
    end)
  end)

  describe("memory context", function()
    it("loads project memory from NeoCode data dir", function()
      local tmp = vim.fn.tempname()
      local cwd = vim.fn.tempname()
      vim.fn.mkdir(tmp, "p")
      vim.fn.mkdir(cwd, "p")
      local store = require("neocode.memory").new({ data_dir = tmp, cwd = cwd })
      store.save({ text = "Use pnpm." })

      local msg = session._build_memory_context({ data_dir = tmp }, cwd)

      vim.fn.delete(tmp, "rf")
      vim.fn.delete(cwd, "rf")
      assert.equals("system", msg.role)
      assert.is_true(msg._is_memory_context)
      assert.is_truthy(msg.content:find("Use pnpm.", 1, true))
    end)
  end)

  describe("skills context", function()
    it("loads manually selected skills from NeoCode data dir", function()
      local tmp = vim.fn.tempname()
      vim.fn.mkdir(tmp, "p")
      local store = require("neocode.skills").new({ data_dir = tmp })
      store.save("laravel", "Use Laravel conventions.")

      local msg = session._build_skills_context({ data_dir = tmp, selected_skills = { "laravel" } })

      vim.fn.delete(tmp, "rf")
      assert.equals("system", msg.role)
      assert.is_true(msg._is_skills_context)
      assert.is_truthy(msg.content:find("Use Laravel conventions.", 1, true))
    end)
  end)

  describe("local memory and skill commands", function()
    it("opens session history for /session", function()
      local picked_config = nil
      local old_history = package.loaded["neocode.history"]
      package.loaded["neocode.history"] = {
        pick = function(config)
          picked_config = config
        end,
      }
      local config = { data_dir = vim.fn.tempname() }

      local ok, err = pcall(function()
        assert.is_true(session._handle_local_command("/session", {}, config))
      end)

      package.loaded["neocode.history"] = old_history
      assert.is_true(ok, err)
      assert.equals(config, picked_config)
    end)

    it("handles /thinking through the active API adapter", function()
      local notified = {}
      local old_notify = vim.notify
      vim.notify = function(message, level)
        table.insert(notified, { message = message, level = level })
      end
      local record = {
        api_adapter = {
          set_thinking = function(mode)
            assert.equals("low", mode)
            return true, "thinking mode: low"
          end,
        },
      }

      local ok, err = pcall(function()
        assert.is_true(session._handle_local_command("/thinking low", record, {}))
      end)

      vim.notify = old_notify
      assert.is_true(ok, err)
      assert.equals("neocode: thinking mode: low", notified[1].message)
    end)

    it("shows unavailable when /thinking is rejected by the adapter", function()
      local notified = {}
      local old_notify = vim.notify
      vim.notify = function(message, level)
        table.insert(notified, { message = message, level = level })
      end
      local record = {
        api_adapter = {
          set_thinking = function()
            return false, "Thinking mode not available"
          end,
        },
      }

      local ok, err = pcall(function()
        assert.is_true(session._handle_local_command("/thinking high", record, {}))
      end)

      vim.notify = old_notify
      assert.is_true(ok, err)
      assert.equals("neocode: Thinking mode not available", notified[1].message)
    end)

    it("handles /thinking without arguments as an interactive picker", function()
      local notified = {}
      local old_notify = vim.notify
      local old_select = vim.ui.select
      vim.notify = function(message, level)
        table.insert(notified, { message = message, level = level })
      end
      vim.ui.select = function(items, opts, cb)
        assert.are.same({ "off", "low", "medium", "high", "max" }, items)
        assert.equals("NeoCode thinking mode", opts.prompt)
        cb("medium")
      end
      local record = {
        api_adapter = {
          set_thinking = function(mode)
            assert.equals("medium", mode)
            return true, "thinking mode: medium (enabled for next request; confirmed by slots reasoning_format=deepseek)"
          end,
        },
      }

      local ok, err = pcall(function()
        assert.is_true(session._handle_local_command("/thinking", record, {}))
      end)

      vim.notify = old_notify
      vim.ui.select = old_select
      assert.is_true(ok, err)
      assert.equals("neocode: thinking mode: medium (enabled for next request; confirmed by slots reasoning_format=deepseek)", notified[1].message)
    end)

    it("clears the inline draft after handling /thinking", function()
      local old_notify = vim.notify
      vim.notify = function() end
      local buf = vim.api.nvim_create_buf(false, true)
      local record = {
        id = "thinking-clear",
        adapter = "local",
        title = "Thinking clear",
        created_at = 123,
        bufnr = buf,
        messages = {},
        api_adapter = {
          set_thinking = function(mode)
            assert.equals("low", mode)
            return true, "thinking mode: low"
          end,
        },
      }

      local ok, err = pcall(function()
        session._open_api_input(record, { data_dir = vim.fn.tempname() }, {
          initial_lines = { "Me:", "/thinking low" },
          auto_send = true,
        })

        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        assert.are.same({
          "Me:",
          "",
          "Press <C-s>, <C-CR>, or <M-CR> to send",
        }, lines)
      end)

      vim.notify = old_notify
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
      assert.is_true(ok, err)
    end)

    it("clears the inline draft after interactive /thinking selection", function()
      local old_notify = vim.notify
      local old_select = vim.ui.select
      vim.notify = function() end
      vim.ui.select = function(_, _, cb) cb("medium") end
      local buf = vim.api.nvim_create_buf(false, true)
      local record = {
        id = "thinking-picker-clear",
        adapter = "local",
        title = "Thinking picker clear",
        created_at = 123,
        bufnr = buf,
        messages = {},
        api_adapter = {
          set_thinking = function(mode)
            assert.equals("medium", mode)
            return true, "thinking mode: medium"
          end,
        },
      }

      local ok, err = pcall(function()
        session._open_api_input(record, { data_dir = vim.fn.tempname() }, {
          initial_lines = { "Me:", "/thinking" },
          auto_send = true,
        })

        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        assert.are.same({
          "Me:",
          "",
          "Press <C-s>, <C-CR>, or <M-CR> to send",
        }, lines)
      end)

      vim.notify = old_notify
      vim.ui.select = old_select
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
      assert.is_true(ok, err)
    end)

    it("handles /memory save without writing to the project tree", function()
      local tmp = vim.fn.tempname()
      local cwd = vim.fn.tempname()
      vim.fn.mkdir(tmp, "p")
      vim.fn.mkdir(cwd, "p")
      local record = { cwd = cwd }

      assert.is_true(session._handle_local_command("/memory save Use pnpm.", record, { data_dir = tmp }))

      local msg = session._build_memory_context({ data_dir = tmp }, cwd)
      vim.fn.delete(tmp, "rf")
      vim.fn.delete(cwd, "rf")
      assert.is_truthy(msg.content:find("Use pnpm.", 1, true))
    end)

    it("handles /skill save and /skill select", function()
      local tmp = vim.fn.tempname()
      vim.fn.mkdir(tmp, "p")
      local config = { data_dir = tmp }

      assert.is_true(session._handle_local_command("/skill save laravel Use Laravel conventions.", {}, config))
      assert.is_true(session._handle_local_command("/skill select laravel", {}, config))

      local msg = session._build_skills_context(config)
      vim.fn.delete(tmp, "rf")
      assert.same({ "laravel" }, config.selected_skills)
      assert.is_truthy(msg.content:find("Use Laravel conventions.", 1, true))
    end)
  end)

  describe("api input composer", function()
    it("strips the visible Me prompt marker before sending", function()
      assert.equals("hello", session._api_input_text_from_lines({ "Me:", "hello" }))
      assert.equals("multi\nline", session._api_input_text_from_lines({ "Me:", "", "multi", "line", "", "Press <C-s>, <C-CR>, or <M-CR> to send" }))
      assert.equals("multi\nline", session._api_input_text_from_lines({ "Me:", "", "multi", "line", "", "Press <C-s> or <M-CR> to send" }))
    end)

    it("treats a prompt-only input window as empty", function()
      assert.equals("", session._api_input_text_from_lines({ "Me:", "" }))
    end)

    it("builds visible Me-prefixed draft lines from inline chat text", function()
      assert.are.same({ "Me:", "hello", "world" }, session._api_input_lines_from_text("hello\nworld"))
    end)

    it("extracts only the bottom inline draft from a rendered transcript", function()
      assert.equals("next prompt", session._api_inline_draft_text_from_lines({
        "━━━━━━ You ━━━━━━",
        "old prompt",
        "━━━━━━━━━━━━━━━━━━",
        "",
        "━━━ Assistant ━━━",
        "old answer",
        "━━━━━━━━━━━━━━━━━━",
        "",
        "Me:",
        "next prompt",
        "Press <C-s>, <C-CR>, or <M-CR> to send",
      }))
    end)

    it("sends all pending API images once and clears them after send", function()
      local tmp = vim.fn.tempname()
      vim.fn.mkdir(tmp, "p")
      local buf = vim.api.nvim_create_buf(false, true)
      local local_adapter = require("neocode.adapters.local")
      local_adapter.setup({ model = "local-model", read_json = function() return nil end })
      local sent_messages = nil
      local_adapter.stream = function(messages, _, on_complete)
        sent_messages = vim.deepcopy(messages)
        on_complete("ok", { usage = { prompt_tokens = 1, completion_tokens = 1, total_tokens = 2 } })
        return 77
      end
      local record = {
        id = "api-images-clear",
        adapter = "local",
        title = "API images clear",
        created_at = 123,
        bufnr = buf,
        messages = {},
        pending_images_b64 = { "abc123", "def456" },
        api_adapter = local_adapter,
        cwd = tmp,
      }
      session._add(record)

      local ok, err = pcall(function()
        session._open_api_input(record, { data_dir = tmp }, {
          initial_lines = { "Me:", "compare <image0> and <image1>" },
          auto_send = true,
        })
      end)

      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
      session._remove(record.id)
      vim.fn.delete(tmp, "rf")

      assert.is_true(ok, err)
      assert.same({}, record.pending_images_b64)
      assert.equals("compare <image0> and <image1>", sent_messages[1].content[1].text)
      assert.equals("data:image/png;base64,abc123", sent_messages[1].content[2].image_url.url)
      assert.equals("data:image/png;base64,def456", sent_messages[1].content[3].image_url.url)
    end)
  end)

  describe("stalled assistant continuation", function()
    it("detects short action promises that did not make progress", function()
      assert.is_true(session._assistant_stalled_after_action_promise("Let me look at it."))
      assert.is_true(session._assistant_stalled_after_action_promise("I'll inspect the file."))
      assert.is_true(session._assistant_stalled_after_action_promise("I will run the tests now."))
    end)

    it("does not flag clarification questions or completed work", function()
      assert.is_false(session._assistant_stalled_after_action_promise("Which file should I inspect?"))
      assert.is_false(session._assistant_stalled_after_action_promise("I inspected the file and found the issue: the handler returns early."))
      assert.is_false(session._assistant_stalled_after_action_promise("I cannot inspect that without a file path."))
    end)

    it("auto-continues once when the assistant stops after promising action", function()
      local tmp = vim.fn.tempname()
      vim.fn.mkdir(tmp, "p")
      local buf = vim.api.nvim_create_buf(false, true)
      local stream_calls = 0
      local adapter = {
        name = "local",
        type = "api",
        config = { base_url = "http://127.0.0.1:8080", model = "local" },
        _build_user_message = function(text) return { role = "user", content = text } end,
        stream = function(messages, _, on_complete)
          stream_calls = stream_calls + 1
          if stream_calls == 1 then
            on_complete("Let me look at it.", { usage = { prompt_tokens = 1, completion_tokens = 1, total_tokens = 2 } })
          else
            assert.is_truthy((messages[#messages - 1].content or ""):find("You said you were going to", 1, true))
            on_complete("I inspected it and found the next step.", { usage = { prompt_tokens = 2, completion_tokens = 2, total_tokens = 4 } })
          end
          return 88 + stream_calls
        end,
      }
      local record = {
        id = "stalled-auto-continue",
        adapter = "local",
        title = "Stalled auto continue",
        created_at = 123,
        bufnr = buf,
        messages = {},
        api_adapter = adapter,
        cwd = tmp,
      }
      session._add(record)

      local ok, err = pcall(function()
        session._open_api_input(record, { data_dir = tmp }, {
          initial_lines = { "Me:", "can you help with this?" },
          auto_send = true,
        })
      end)

      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
      session._remove(record.id)
      vim.fn.delete(tmp, "rf")

      assert.is_true(ok, err)
      assert.equals(2, stream_calls)
    end)
  end)

  describe("api chat metadata display", function()
    it("shows supported thinking mode and bottom context usage in refreshed local chat", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local record = {
        bufnr = buf,
        messages = {
          { role = "assistant", content = "done", _stats = { usage = { prompt_tokens = 12000, completion_tokens = 288 } } },
        },
        api_adapter = {
          config = { context_size = 24576, thinking = "medium" },
          thinking_available = function() return true end,
          thinking_mode = function() return "medium" end,
        },
      }

      session._refresh_api_chat(record, { draft = true, editable = true })

      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      vim.api.nvim_buf_delete(buf, { force = true })
      assert.equals("Thinking: medium", lines[1])
      assert.is_truthy(table.concat(lines, "\n"):find("12.3k / 24.6k context used", 1, true))
      assert.is_truthy(vim.tbl_contains(lines, "Me:"))
    end)

    it("does not update context usage before a completed assistant response", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local record = {
        bufnr = buf,
        messages = {
          { role = "assistant", content = "", _stats = { usage = { prompt_tokens = 12000, completion_tokens = 288 } } },
        },
        api_adapter = {
          config = { context_size = 24576 },
          thinking_available = function() return false end,
        },
      }

      session._refresh_api_chat(record, { draft = true, editable = true })

      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      vim.api.nvim_buf_delete(buf, { force = true })
      assert.equals("Me:", lines[1])
    end)

    it("hides thinking mode when the adapter does not support thinking", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local record = {
        bufnr = buf,
        messages = {},
        api_adapter = {
          config = { context_size = 32768, thinking = "high" },
          thinking_available = function() return false end,
          thinking_mode = function() return "high" end,
        },
      }

      session._refresh_api_chat(record, { draft = true, editable = true })

      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      vim.api.nvim_buf_delete(buf, { force = true })
      assert.equals("Me:", lines[1])
      assert.is_falsy(table.concat(lines, "\n"):find("Thinking:", 1, true))
    end)

    it("keeps chat refresh working when adapter thinking helpers fail", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local record = {
        bufnr = buf,
        messages = {},
        api_adapter = {
          config = { context_size = 16384, thinking = "high" },
          thinking_available = function() error("probe failed") end,
          thinking_mode = function() error("mode failed") end,
        },
      }

      assert.has_no_error(function()
        session._refresh_api_chat(record, { draft = true, editable = true })
      end)

      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      vim.api.nvim_buf_delete(buf, { force = true })
      assert.equals("Me:", lines[1])
      assert.is_falsy(table.concat(lines, "\n"):find("Thinking:", 1, true))
    end)

    it("refreshes adapter metadata before rendering API chat", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local refreshed = false
      local record = {
        bufnr = buf,
        messages = {
          { role = "assistant", content = "done", _stats = { usage = { prompt_tokens = 32000, completion_tokens = 1000 } } },
        },
        api_adapter = {
          config = { context_size = 32768 },
          refresh_metadata = function(adapter)
            refreshed = true
            adapter.config.context_size = 64000
            return true
          end,
        },
      }

      session._refresh_api_chat(record, { draft = true, editable = true, refresh_metadata = true })

      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      vim.api.nvim_buf_delete(buf, { force = true })
      assert.is_true(refreshed)
      assert.is_truthy(table.concat(lines, "\n"):find("33k / 64k context used", 1, true))
    end)
  end)

  describe("_extract_direct_read_path", function()
    it("extracts an explicit absolute file path from read prompts", function()
      assert.equals(
        "/Users/johnkarlo/.config/nvim/init.lua",
        session._extract_direct_read_path("Read /Users/johnkarlo/.config/nvim/init.lua and summarize it")
      )
    end)

    it("extracts an explicit relative file path using cwd", function()
      assert.equals(
        "/project/plan.md",
        session._extract_direct_read_path("Can you read plan.md?", "/project")
      )
    end)

    it("does not extract paths from broad project requests", function()
      assert.is_nil(session._extract_direct_read_path("Can you read this project?", "/project"))
    end)

    it("extracts README when the user asks to read the readme", function()
      assert.equals(
        "/project/README.md",
        session._extract_direct_read_path("Hi, can you read the readme and tell me what the project is about?", "/project")
      )
    end)

    it("extracts paths from /readfile commands", function()
      assert.equals(
        "/project/README.md",
        session._extract_direct_read_path("/readfile README.md", "/project")
      )
    end)
  end)

  describe("_direct_read_fast_path", function()
    it("allows explicit project prefix for exact file reads", function()
      assert.equals(
        "/project/plan.md",
        session._direct_read_fast_path("@project read plan.md and summarize it", "/project")
      )
    end)

    it("allows /readfile for exact file reads", function()
      assert.equals(
        "/project/README.md",
        session._direct_read_fast_path("/readfile README.md", "/project")
      )
    end)

    it("does not fast path mixed broad project requests", function()
      assert.is_nil(session._direct_read_fast_path("read package.json and inspect the project", "/project"))
    end)
  end)

  describe("_build_direct_file_context_message", function()
    it("builds a bounded context message for direct file reads", function()
      local msg = session._build_direct_file_context_message("/tmp/example.lua", "print('hello')")

      assert.equals("system", msg.role)
      assert.is_true(msg._is_direct_file_context)
      assert.is_truthy(msg.content:find("/tmp/example.lua", 1, true))
      assert.is_truthy(msg.content:find("print('hello')", 1, true))
    end)
  end)

  describe("auto compaction helpers", function()
    it("uses runtime context size from stats before adapter or config fallbacks", function()
      local stale_config_context = 16384
      local adapter_context = 32768
      local current_model_context = 24576
      local record = {
        api_adapter = {
          config = { context_size = adapter_context },
        },
      }
      local config = {
        auto_compact = { context_size = stale_config_context },
      }

      assert.equals(current_model_context, session._auto_compact_context_size(config, record, { context_size = current_model_context }))
    end)

    it("ignores auto compact context_size settings in favor of adapter metadata", function()
      local stale_config_context = 16384
      local current_model_context = 32768
      local record = {
        api_adapter = {
          config = { context_size = current_model_context },
        },
      }

      assert.equals(current_model_context, session._auto_compact_context_size({
        auto_compact = { context_size = stale_config_context },
      }, record, {}))
    end)

    it("uses current model context size when deciding the compaction threshold", function()
      local smaller_runtime_context = 32768
      local larger_runtime_context = 65536
      local used_tokens = 50000
      local record = {
        api_adapter = {
          config = { context_size = smaller_runtime_context },
        },
      }

      assert.is_false(session._should_auto_compact({}, record, {
        context_size = larger_runtime_context,
        usage = { prompt_tokens = used_tokens, completion_tokens = 0 },
      }))
      assert.is_true(session._should_auto_compact({}, record, {
        context_size = smaller_runtime_context,
        usage = { prompt_tokens = used_tokens, completion_tokens = 0 },
      }))
    end)

    it("falls back to adapter context size", function()
      local record = {
        api_adapter = {
          config = { context_size = 24576 },
        },
      }

      assert.equals(24576, session._auto_compact_context_size({}, record, {}))
    end)

    it("requires an OpenAI-compatible compact endpoint before compacting", function()
      assert.is_nil(session._compact_endpoint_config({ api_adapter = { config = {} } }))
      assert.is_nil(session._compact_endpoint_config({ api_adapter = { name = "cli" } }))

      assert.are.same({ base_url = "http://127.0.0.1:8080", model = "local" }, session._compact_endpoint_config({
        api_adapter = { config = { base_url = "http://127.0.0.1:8080", model = "local" } },
      }))
    end)

    it("builds compact chat URLs without duplicating v1", function()
      assert.equals("http://127.0.0.1:8080/v1/chat/completions", session._compact_chat_url({
        api_adapter = { config = { base_url = "http://127.0.0.1:8080/v1", model = "local" } },
      }))
      assert.equals("http://127.0.0.1:8080/v1/chat/completions", session._compact_chat_url({
        api_adapter = { config = { base_url = "http://127.0.0.1:8080", model = "local" } },
      }))
    end)

    it("detects when prompt usage crosses configured threshold", function()
      local record = {
        api_adapter = {
          config = { context_size = 24576 },
        },
      }
      local config = { auto_compact = { threshold = 0.8 } }

      assert.is_false(session._should_auto_compact(config, record, { prompt_tokens = 19000 }))
      assert.is_true(session._should_auto_compact(config, record, { prompt_tokens = 20000 }))
    end)

    it("auto compacts by default when enabled is omitted", function()
      local current_model_context = 32768
      local near_full_usage = 32000
      local record = {
        api_adapter = {
          config = { context_size = current_model_context },
        },
      }
      local config = {
        auto_compact = { threshold = 0.8 },
      }

      assert.is_true(session._should_auto_compact(config, record, { prompt_tokens = near_full_usage }))
    end)

    it("does not expose auto compaction as a disable switch", function()
      local current_model_context = 32768
      local near_full_usage = 32000
      local record = {
        api_adapter = { config = { context_size = current_model_context } },
      }

      assert.is_true(session._should_auto_compact({ auto_compact = { enabled = false } }, record, { prompt_tokens = near_full_usage }))
    end)

    it("does not compact while already compacting", function()
      local record = {
        _auto_compact_running = true,
        api_adapter = { config = { context_size = 24576 } },
      }

      assert.is_false(session._should_auto_compact({ auto_compact = {} }, record, { prompt_tokens = 24576 }))
    end)

    it("marks the next turn for compaction after a high-context response", function()
      local record = {
        api_adapter = { config = { context_size = 24576, base_url = "http://127.0.0.1:8080", model = "local" } },
      }
      local config = { auto_compact = { threshold = 0.8 } }

      assert.is_true(session._mark_auto_compact_if_needed(config, record, { prompt_tokens = 20000 }))
      assert.is_true(record._auto_compact_pending)
      assert.equals(20000, record._auto_compact_last_usage.prompt_tokens)
      assert.equals(24576, record._auto_compact_last_usage.context_size)
    end)

    it("marks auto compaction from parsed overflow error stats", function()
      local record = {
        api_adapter = { config = { context_size = 64000, base_url = "http://127.0.0.1:8080", model = "local" } },
      }
      local config = { auto_compact = { threshold = 0.8 } }

      assert.is_true(session._mark_auto_compact_if_needed(config, record, {
        error = true,
        context_size = 32768,
        usage = { prompt_tokens = 33170, completion_tokens = 0, total_tokens = 33170 },
      }))
      assert.is_true(record._auto_compact_pending)
      assert.equals(33170, record._auto_compact_last_usage.used_tokens)
      assert.equals(32768, record._auto_compact_last_usage.context_size)
    end)

    it("preserves the requested number of recent turns for compacted history", function()
      local messages = {
        { role = "user", content = "old question" },
        { role = "assistant", content = "old answer" },
        { role = "user", content = "recent question" },
        { role = "assistant", content = "recent answer" },
      }

      assert.are.same({
        { role = "user", content = "recent question" },
        { role = "assistant", content = "recent answer" },
      }, session._auto_compact_recent_messages(messages, 1))
    end)

    it("summarizes only older messages when recent turns are preserved", function()
      local messages = {
        { role = "user", content = "old question" },
        { role = "assistant", content = "old answer" },
        { role = "user", content = "recent question" },
        { role = "assistant", content = "recent answer" },
      }

      assert.are.same({
        { role = "user", content = "old question" },
        { role = "assistant", content = "old answer" },
      }, session._auto_compact_messages_to_summarize(messages, 1))
    end)

    it("repairs compact summaries that miss required durable sections", function()
      local summary = session._ensure_structured_compact_summary("Already captured detail.")

      assert.is_truthy(summary:find("## Summary", 1, true))
      assert.is_truthy(summary:find("Already captured detail.", 1, true))
      assert.is_truthy(summary:find("## User Preferences\n- Not captured.", 1, true))
      assert.is_truthy(summary:find("## Decisions\n- Not captured.", 1, true))
      assert.is_truthy(summary:find("## Files / Code Context\n- Not captured.", 1, true))
      assert.is_truthy(summary:find("## Completed\n- Not captured.", 1, true))
      assert.is_truthy(summary:find("## Open Tasks\n- Not captured.", 1, true))
      assert.is_truthy(summary:find("## Important Exact Details\n- Not captured.", 1, true))
    end)

    it("reorders compact summary sections and trims heading whitespace", function()
      local summary = session._ensure_structured_compact_summary(table.concat({
        "Loose preamble detail.",
        "## Open Tasks  ",
        "- Finish verification.",
        "## Decisions",
        "- Preserve main on a feature branch.",
      }, "\n"))

      local summary_pos = summary:find("## Summary", 1, true)
      local decisions_pos = summary:find("## Decisions", 1, true)
      local open_tasks_pos = summary:find("## Open Tasks", 1, true)
      assert.is_truthy(summary_pos)
      assert.is_truthy(decisions_pos)
      assert.is_truthy(open_tasks_pos)
      assert.is_true(summary_pos < decisions_pos)
      assert.is_true(decisions_pos < open_tasks_pos)
      assert.is_truthy(summary:find("Loose preamble detail.", 1, true))
      assert.is_truthy(summary:find("## Decisions\n- Preserve main on a feature branch.", 1, true))
      assert.is_truthy(summary:find("## Open Tasks\n- Finish verification.", 1, true))
    end)

    it("continues from compacted summary and clears stale high-context usage", function()
      local tmp_dir = vim.fn.tempname()
      vim.fn.mkdir(tmp_dir, "p")
      local buf = vim.api.nvim_create_buf(false, true)
      local record = {
        id = "compact-reset",
        adapter = "llama",
        title = "Compact reset",
        created_at = 123,
        cwd = "/tmp/project",
        bufnr = buf,
        api_adapter = {
          config = { base_url = "http://127.0.0.1:8080", model = "local-model" },
        },
        messages = {
          { role = "user", content = "old question" },
          { role = "assistant", content = "old answer" },
          { role = "user", content = "recent question" },
          { role = "assistant", content = "recent answer" },
        },
        _auto_compact_pending = true,
        _auto_compact_last_usage = { used_tokens = 20000, context_size = 24576 },
      }
      local config = {
        data_dir = tmp_dir,
        auto_compact = { preserve_recent_turns = 1 },
      }
      local original_jobstart = vim.fn.jobstart
      vim.fn.jobstart = function(argv, opts)
        local payload
        for i, arg in ipairs(argv or {}) do
          if arg == "-d" then
            payload = vim.fn.json_decode(argv[i + 1] or "{}")
            break
          end
        end
        assert.is_table(payload)
        assert.is_false(payload.enable_thinking)
        assert.is_table(payload.chat_template_kwargs)
        assert.is_false(payload.chat_template_kwargs.enable_thinking)
        assert.equals(900, payload.max_tokens)
        assert.is_table(payload.messages)
        assert.is_truthy(payload.messages[1].content:find("Return only markdown with these exact level%-2 headings", 1, false))
        assert.is_truthy(payload.messages[1].content:find("## Summary", 1, true))
        assert.is_truthy(payload.messages[1].content:find("## User Preferences", 1, true))
        assert.is_truthy(payload.messages[1].content:find("## Decisions", 1, true))
        assert.is_truthy(payload.messages[1].content:find("## Files / Code Context", 1, true))
        assert.is_truthy(payload.messages[1].content:find("## Completed", 1, true))
        assert.is_truthy(payload.messages[1].content:find("## Open Tasks", 1, true))
        assert.is_truthy(payload.messages[1].content:find("## Important Exact Details", 1, true))
        opts.on_stdout(1, {
          vim.fn.json_encode({
            choices = {
              { message = { content = "## Summary\n- Compacted summary of the old conversation.\n\n## Open Tasks\n- Continue from recent question." } },
            },
          }),
        })
        return 99
      end

      local ok, err = pcall(function()
        assert.is_true(session._compact_session(record, config))
        vim.wait(1000, function()
          return record._auto_compact_running == false
        end)

        assert.are.same({
          { role = "user", content = "Summarize our conversation so far." },
          { role = "assistant", content = "Here is a summary of our conversation:\n\n## Summary\n- Compacted summary of the old conversation.\n\n## User Preferences\n- Not captured.\n\n## Decisions\n- Not captured.\n\n## Files / Code Context\n- Not captured.\n\n## Completed\n- Not captured.\n\n## Open Tasks\n- Continue from recent question.\n\n## Important Exact Details\n- Not captured." },
          { role = "user", content = "recent question" },
          { role = "assistant", content = "recent answer" },
        }, record.messages)
        assert.is_nil(record._auto_compact_last_usage)
        assert.is_false(record._auto_compact_pending)
        assert.is_false(record._auto_compact_running)
        local saved = session._load_api_messages(config, record)
        assert.equals("Here is a summary of our conversation:\n\n## Summary\n- Compacted summary of the old conversation.\n\n## User Preferences\n- Not captured.\n\n## Decisions\n- Not captured.\n\n## Files / Code Context\n- Not captured.\n\n## Completed\n- Not captured.\n\n## Open Tasks\n- Continue from recent question.\n\n## Important Exact Details\n- Not captured.", saved[2].content)
      end)

      vim.fn.jobstart = original_jobstart
      vim.fn.delete(tmp_dir, "rf")
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
      assert.is_true(ok, err)
    end)
  end)

  it("creates a record with correct fields", function()
    local s = session._new_record("claude", "Test session")
    assert.is_not_nil(s.id)
    assert.equals("claude", s.adapter)
    assert.equals("Test session", s.title)
    assert.is_number(s.created_at)
    -- runtime fields start nil (set when buffer is opened)
    assert.is_nil(s.bufnr)
    assert.is_nil(s.job_id)
  end)

  it("_add() makes session retrievable by id", function()
    local s = session._new_record("claude", "My chat")
    session._add(s)
    assert.equals(s, session._get(s.id))
  end)

  it("_remove() deletes session from table", function()
    local s = session._new_record("claude", "Temp")
    session._add(s)
    session._remove(s.id)
    assert.is_nil(session._get(s.id))
  end)

  it("delete_active switches current session to the remaining displayed session", function()
    local win = vim.api.nvim_get_current_win()
    local first = session._new_record("local", "First")
    local second = session._new_record("local", "Second")
    first.messages = { { role = "user", content = "first" } }
    second.messages = { { role = "user", content = "second" } }
    first.bufnr = vim.api.nvim_create_buf(false, true)
    second.bufnr = vim.api.nvim_create_buf(false, true)
    session._add(first)
    session._add(second)
    session._show_session_in_window(first, win)

    local ok, err = pcall(function()
      assert.is_true(session.delete_active(first.id, { data_dir = vim.fn.tempname() }))
    end)

    if second.bufnr and vim.api.nvim_buf_is_valid(second.bufnr) then
      vim.api.nvim_buf_delete(second.bufnr, { force = true })
    end
    assert.is_true(ok, err)
    assert.equals(second, session._current())
  end)

  it("delete_active removes legacy llama history files", function()
    local tmp = vim.fn.tempname()
    local legacy_dir = tmp .. "/llama"
    local llama_session = require("neocode.llama_session")
    local record = session._new_record("llama", "Legacy")
    record.bufnr = vim.api.nvim_create_buf(false, true)
    session._add(record)
    llama_session.save(legacy_dir, record.id, { { role = "user", content = "old" } })

    local ok, err = pcall(function()
      assert.is_true(session.delete_active(record.id, { data_dir = tmp }))
    end)

    local exists = vim.fn.filereadable(llama_session._path(legacy_dir, record.id)) == 1
    vim.fn.delete(tmp, "rf")
    assert.is_true(ok, err)
    assert.is_false(exists)
  end)

  it("delete_active prevents late API callbacks from recreating deleted sessions", function()
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    local buf = vim.api.nvim_create_buf(false, true)
    local complete = nil
    local adapter = {
      name = "local",
      type = "api",
      config = { base_url = "http://127.0.0.1:8080", model = "local" },
      _build_user_message = function(text) return { role = "user", content = text } end,
      stream = function(_, _, on_complete)
        complete = on_complete
        return 99
      end,
    }
    local record = {
      id = "deleted-late-callback",
      adapter = "local",
      title = "Deleted late callback",
      created_at = 123,
      bufnr = buf,
      messages = {},
      api_adapter = adapter,
      cwd = tmp,
    }
    session._add(record)

    local ok, err = pcall(function()
      session._open_api_input(record, { data_dir = tmp, auto_compact = { enabled = true } }, {
        initial_lines = { "Me:", "hello" },
        auto_send = true,
      })
      assert.is_function(complete)
      assert.is_true(session.delete_active(record.id, { data_dir = tmp }))
      complete("late response", { usage = { prompt_tokens = 1, completion_tokens = 1, total_tokens = 2 } })
    end)

    local entries = session.load_all_from_disk({ data_dir = tmp, adapters = { ["local"] = adapter } })
    vim.fn.delete(tmp, "rf")
    assert.is_true(ok, err)
    assert.equals(0, #entries)
  end)

  it("_all() returns all sessions", function()
    session._add(session._new_record("claude", "A"))
    session._add(session._new_record("claude", "B"))
    assert.equals(2, #session._all())
  end)

  it("reuses the current NeoCode window when creating another CLI session", function()
    local initial_win = vim.api.nvim_get_current_win()
    local initial_windows = #vim.api.nvim_list_wins()
    local old_termopen = vim.fn.termopen
    vim.fn.termopen = function()
      return 9001
    end
    local adapter = {
      name = "mockcli",
      launch_cmd = function()
        return { cmd = "mockcli", args = {} }
      end,
    }

    local ok, err = pcall(function()
      session.create(adapter, "First CLI", { winbar = "" })
      local after_first = #vim.api.nvim_list_wins()
      session.create(adapter, "Second CLI", { winbar = "" })
      local after_second = #vim.api.nvim_list_wins()
      local first, second
      for _, s in ipairs(session._all()) do
        if s.title == "First CLI" then first = s end
        if s.title == "Second CLI" then second = s end
      end

      assert.equals(initial_windows + 1, after_first)
      assert.equals(after_first, after_second)
      assert.is_nil(first.winid)
      assert.is_number(second.winid)
      assert.is_true(vim.api.nvim_win_is_valid(second.winid))
    end)

    vim.fn.termopen = old_termopen
    for _, s in ipairs(session._all()) do
      if s.bufnr and vim.api.nvim_buf_is_valid(s.bufnr) then
        pcall(vim.api.nvim_buf_delete, s.bufnr, { force = true })
      end
    end
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if win ~= initial_win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
    if vim.api.nvim_win_is_valid(initial_win) then
      vim.api.nvim_set_current_win(initial_win)
    end
    assert.is_true(ok, err)
  end)

  it("reuses the current NeoCode window when creating another API session", function()
    local initial_win = vim.api.nvim_get_current_win()
    local initial_windows = #vim.api.nvim_list_wins()
    local adapter = {
      name = "local",
      type = "api",
      config = { context_size = 32768 },
    }

    local ok, err = pcall(function()
      session.create(adapter, "First API", { data_dir = vim.fn.tempname(), winbar = "" })
      local after_first = #vim.api.nvim_list_wins()
      session.create(adapter, "Second API", { data_dir = vim.fn.tempname(), winbar = "" })
      local after_second = #vim.api.nvim_list_wins()
      local first, second
      for _, s in ipairs(session._all()) do
        if s.title == "First API" then first = s end
        if s.title == "Second API" then second = s end
      end

      assert.equals(initial_windows + 1, after_first)
      assert.equals(after_first, after_second)
      assert.is_nil(first.winid)
      assert.is_number(second.winid)
      assert.is_true(vim.api.nvim_win_is_valid(second.winid))
    end)

    for _, s in ipairs(session._all()) do
      if s.bufnr and vim.api.nvim_buf_is_valid(s.bufnr) then
        pcall(vim.api.nvim_buf_delete, s.bufnr, { force = true })
      end
    end
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if win ~= initial_win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
    if vim.api.nvim_win_is_valid(initial_win) then
      vim.api.nvim_set_current_win(initial_win)
    end
    assert.is_true(ok, err)
  end)

  it("reclaims window ownership when switching back to a reused API session", function()
    local initial_win = vim.api.nvim_get_current_win()
    local adapter = {
      name = "local",
      type = "api",
      config = { context_size = 32768 },
    }

    local ok, err = pcall(function()
      session.create(adapter, "First API", { data_dir = vim.fn.tempname(), winbar = "" })
      session.create(adapter, "Second API", { data_dir = vim.fn.tempname(), winbar = "" })
      local first, second
      for _, s in ipairs(session._all()) do
        if s.title == "First API" then first = s end
        if s.title == "Second API" then second = s end
      end

      local reused_win = second.winid
      assert.is_nil(first.winid)
      assert.is_true(session._show_session_in_window(first, reused_win))
      assert.equals(reused_win, first.winid)
      assert.is_nil(second.winid)
      assert.equals(first, session._current())

      session.hide()
      assert.is_nil(first.winid)
      assert.is_false(vim.api.nvim_win_is_valid(reused_win))
    end)

    for _, s in ipairs(session._all()) do
      if s.bufnr and vim.api.nvim_buf_is_valid(s.bufnr) then
        pcall(vim.api.nvim_buf_delete, s.bufnr, { force = true })
      end
    end
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if win ~= initial_win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
    if vim.api.nvim_win_is_valid(initial_win) then
      vim.api.nvim_set_current_win(initial_win)
    end
    assert.is_true(ok, err)
  end)

  it("reclaims window ownership when cycling back to a reused API session", function()
    local initial_win = vim.api.nvim_get_current_win()
    local adapter = {
      name = "local",
      type = "api",
      config = { context_size = 32768 },
    }

    local ok, err = pcall(function()
      session.create(adapter, "First API", { data_dir = vim.fn.tempname(), winbar = "" })
      session.create(adapter, "Second API", { data_dir = vim.fn.tempname(), winbar = "" })
      local first, second
      for _, s in ipairs(session._all()) do
        if s.title == "First API" then first = s end
        if s.title == "Second API" then second = s end
      end

      local reused_win = second.winid
      session.cycle("prev", { winbar = "" })

      assert.equals(first, session._current())
      assert.equals(reused_win, first.winid)
      assert.is_nil(second.winid)
      assert.equals(first.bufnr, vim.api.nvim_win_get_buf(reused_win))
    end)

    for _, s in ipairs(session._all()) do
      if s.bufnr and vim.api.nvim_buf_is_valid(s.bufnr) then
        pcall(vim.api.nvim_buf_delete, s.bufnr, { force = true })
      end
    end
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if win ~= initial_win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
    if vim.api.nvim_win_is_valid(initial_win) then
      vim.api.nvim_set_current_win(initial_win)
    end
    assert.is_true(ok, err)
  end)

  it("reclaims window ownership when resuming an in-memory API session", function()
    local initial_win = vim.api.nvim_get_current_win()
    local adapter = {
      name = "local",
      type = "api",
      config = { context_size = 32768 },
    }

    local ok, err = pcall(function()
      session.create(adapter, "First API", { data_dir = vim.fn.tempname(), winbar = "" })
      session.create(adapter, "Second API", { data_dir = vim.fn.tempname(), winbar = "" })
      local first, second
      for _, s in ipairs(session._all()) do
        if s.title == "First API" then first = s end
        if s.title == "Second API" then second = s end
      end

      local reused_win = second.winid
      session.resume_api(adapter, { id = first.id, title = first.title, cwd = first.cwd }, { data_dir = vim.fn.tempname(), winbar = "" })

      assert.equals(first, session._current())
      assert.equals(reused_win, first.winid)
      assert.is_nil(second.winid)
      assert.equals(first.bufnr, vim.api.nvim_win_get_buf(reused_win))
    end)

    for _, s in ipairs(session._all()) do
      if s.bufnr and vim.api.nvim_buf_is_valid(s.bufnr) then
        pcall(vim.api.nvim_buf_delete, s.bufnr, { force = true })
      end
    end
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if win ~= initial_win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
    if vim.api.nvim_win_is_valid(initial_win) then
      vim.api.nvim_set_current_win(initial_win)
    end
    assert.is_true(ok, err)
  end)

  it("claims the window for the remaining session after closing a reclaimed API session", function()
    local initial_win = vim.api.nvim_get_current_win()
    local adapter = {
      name = "local",
      type = "api",
      config = { context_size = 32768 },
    }

    local ok, err = pcall(function()
      session.create(adapter, "First API", { data_dir = vim.fn.tempname(), winbar = "" })
      session.create(adapter, "Second API", { data_dir = vim.fn.tempname(), winbar = "" })
      local first, second
      for _, s in ipairs(session._all()) do
        if s.title == "First API" then first = s end
        if s.title == "Second API" then second = s end
      end

      local reused_win = second.winid
      assert.is_true(session._show_session_in_window(first, reused_win))
      session.close({ data_dir = vim.fn.tempname(), winbar = "" })

      assert.is_nil(session._get(first.id))
      assert.equals(second, session._current())
      assert.equals(reused_win, second.winid)
      assert.is_true(vim.api.nvim_win_is_valid(second.winid))
      assert.equals(second.bufnr, vim.api.nvim_win_get_buf(second.winid))
    end)

    for _, s in ipairs(session._all()) do
      if s.bufnr and vim.api.nvim_buf_is_valid(s.bufnr) then
        pcall(vim.api.nvim_buf_delete, s.bufnr, { force = true })
      end
    end
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if win ~= initial_win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
    if vim.api.nvim_win_is_valid(initial_win) then
      vim.api.nvim_set_current_win(initial_win)
    end
    assert.is_true(ok, err)
  end)

  it("does not reuse a stale session winid that no longer shows its buffer", function()
    local initial_win = vim.api.nvim_get_current_win()
    local initial_windows = #vim.api.nvim_list_wins()
    local adapter = {
      name = "local",
      type = "api",
      config = { context_size = 32768 },
    }

    local ok, err = pcall(function()
      session.create(adapter, "First API", { data_dir = vim.fn.tempname(), winbar = "" })
      local first = session._current()
      local stale_win = first.winid
      local scratch = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_win_set_buf(stale_win, scratch)
      vim.api.nvim_set_current_win(stale_win)

      session.create(adapter, "Second API", { data_dir = vim.fn.tempname(), winbar = "" })
      local second = session._current()

      assert.is_nil(first.winid)
      assert.not_equals(stale_win, second.winid)
      assert.equals(initial_windows + 2, #vim.api.nvim_list_wins())
      assert.equals(scratch, vim.api.nvim_win_get_buf(stale_win))
      assert.equals(second.bufnr, vim.api.nvim_win_get_buf(second.winid))
    end)

    for _, s in ipairs(session._all()) do
      if s.bufnr and vim.api.nvim_buf_is_valid(s.bufnr) then
        pcall(vim.api.nvim_buf_delete, s.bufnr, { force = true })
      end
    end
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if win ~= initial_win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
    if vim.api.nvim_win_is_valid(initial_win) then
      vim.api.nvim_set_current_win(initial_win)
    end
    assert.is_true(ok, err)
  end)

  it("makes a newly opened terminal session current", function()
    local initial_win = vim.api.nvim_get_current_win()
    local old_termopen = vim.fn.termopen
    vim.fn.termopen = function()
      return 9002
    end

    local ok, err = pcall(function()
      local previous = session._new_record("mockcli", "Previous CLI")
      previous.bufnr = vim.api.nvim_get_current_buf()
      previous.winid = initial_win
      session._add(previous)
      assert.is_true(session._show_session_in_window(previous, initial_win))

      local resumed = session._new_record("mockcli", "Resume")
      session._add(resumed)
      session._claim_window_for(resumed, initial_win)
      session._open_terminal(resumed, { "mockcli" }, initial_win, { winbar = "" })

      assert.equals(resumed, session._current())
      assert.equals(initial_win, resumed.winid)
      assert.is_nil(previous.winid)
    end)

    vim.fn.termopen = old_termopen
    for _, s in ipairs(session._all()) do
      if s.bufnr and vim.api.nvim_buf_is_valid(s.bufnr) then
        pcall(vim.api.nvim_buf_delete, s.bufnr, { force = true })
      end
    end
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if win ~= initial_win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
    if vim.api.nvim_win_is_valid(initial_win) then
      vim.api.nvim_set_current_win(initial_win)
    end
    assert.is_true(ok, err)
  end)

  it("generates unique ids", function()
    local a = session._new_record("claude", "A")
    local b = session._new_record("claude", "B")
    assert.not_equals(a.id, b.id)
  end)

  it("renames an in-memory session record", function()
    local s = session._new_record("claude", "Old")
    session._rename_record(s, "New")
    assert.equals("New", s.title)
  end)

  it("does not register a resume keymap for API sessions", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local record = { bufnr = buf }

    session._register_api_keymaps(buf, record, {})

    local maps = vim.api.nvim_buf_get_keymap(buf, "n")
    vim.api.nvim_buf_delete(buf, { force = true })
    for _, map in ipairs(maps) do
      assert.not_equals("<C-S-h>", map.lhs)
      assert.not_equals("<C-h>", map.lhs)
      assert.not_equals("h", map.lhs)
    end
  end)

  it("registers Ctrl-P, not Ctrl-V, for API image paste", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local record = { bufnr = buf }

    session._register_api_keymaps(buf, record, { data_dir = vim.fn.tempname() })

    local maps = vim.api.nvim_buf_get_keymap(buf, "n")
    vim.api.nvim_buf_delete(buf, { force = true })
    local has_ctrl_p = false
    for _, map in ipairs(maps) do
      if map.lhs == "<C-P>" or map.lhs == "<C-p>" then has_ctrl_p = true end
      assert.not_equals("<C-V>", map.lhs)
      assert.not_equals("<C-v>", map.lhs)
    end
    assert.is_true(has_ctrl_p)
  end)

  it("registers Alt-N namespace keymaps for API sessions", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local record = { bufnr = buf }

    session._register_api_keymaps(buf, record, { data_dir = vim.fn.tempname() })

    local normal_maps = vim.api.nvim_buf_get_keymap(buf, "n")
    local insert_maps = vim.api.nvim_buf_get_keymap(buf, "i")
    vim.api.nvim_buf_delete(buf, { force = true })
    local normal = {}
    local insert = {}
    for _, map in ipairs(normal_maps) do normal[map.lhs] = true end
    for _, map in ipairs(insert_maps) do insert[map.lhs] = true end

    assert.is_true(normal["<M-n>q"])
    assert.is_true(normal["<M-n>c"])
    assert.is_true(normal["<M-n>r"])
    assert.is_true(normal["?"])
    assert.is_true(insert["<M-n>q"])
    assert.is_true(insert["<M-n>c"])
    assert.is_true(insert["<M-n>r"])
  end)

  it("does not register a resume keymap for CLI sessions", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local record = { adapter = "mockcli" }

    session._register_buf_keymaps(buf, record, { adapters = {} })

    local maps = vim.api.nvim_buf_get_keymap(buf, "n")
    vim.api.nvim_buf_delete(buf, { force = true })
    for _, map in ipairs(maps) do
      assert.not_equals("<C-S-h>", map.lhs)
      assert.not_equals("<C-h>", map.lhs)
      assert.not_equals("h", map.lhs)
    end
  end)

  it("registers Alt-N namespace keymaps for CLI sessions", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local record = { adapter = "mockcli" }

    session._register_buf_keymaps(buf, record, { adapters = {} })

    local normal_maps = vim.api.nvim_buf_get_keymap(buf, "n")
    local terminal_maps = vim.api.nvim_buf_get_keymap(buf, "t")
    vim.api.nvim_buf_delete(buf, { force = true })
    local normal = {}
    local terminal = {}
    for _, map in ipairs(normal_maps) do normal[map.lhs] = true end
    for _, map in ipairs(terminal_maps) do terminal[map.lhs] = true end

    assert.is_true(normal["<M-n>q"])
    assert.is_true(normal["<M-n>c"])
    assert.is_true(normal["<M-n>r"])
    assert.is_true(normal["?"])
    assert.is_true(terminal["<M-n>q"])
    assert.is_true(terminal["<M-n>c"])
    assert.is_true(terminal["<M-n>r"])
  end)

  it("strips transient web-search system context from saved API messages", function()
    local messages = session._clean_api_messages({
      { role = "system", content = "web search results", _is_web_search = true },
      { role = "user", content = "hello" },
    })

    assert.same({ { role = "user", content = "hello" } }, messages)
  end)

  it("strips transient memory and skills context from saved API messages", function()
    local messages = session._clean_api_messages({
      { role = "system", content = "Project memory", _is_memory_context = true },
      { role = "system", content = "Selected skills", _is_skills_context = true },
      { role = "user", content = "hello" },
    })

    assert.same({ { role = "user", content = "hello" } }, messages)
  end)

  it("strips corrupted local reasoning artifacts from saved assistant messages", function()
    local messages = session._clean_api_messages({
      { role = "user", content = "hello" },
      {
        role = "assistant",
        content = "<|channel>thought\n<channel|>�\nthought-thought-thought-thought-thought-thought-thought-thought\nHere is the saved answer.",
      },
    })

    assert.same({
      { role = "user", content = "hello" },
      { role = "assistant", content = "Here is the saved answer." },
    }, messages)
  end)

  it("normalizes escaped markdown fences in saved assistant messages", function()
    local messages = session._clean_api_messages({
      { role = "assistant", content = "Example:\n\\```lua\nprint('ok')\n\\```" },
    })

    assert.same({
      { role = "assistant", content = "Example:\n```lua\nprint('ok')\n```" },
    }, messages)
  end)

  it("strips image payloads from saved API messages while keeping text", function()
    local messages = session._clean_api_messages({
      {
        role = "user",
        content = {
          { type = "text", text = "look at this" },
          { type = "image_url", image_url = { url = "data:image/png;base64,abc123" } },
        },
      },
    })

    assert.same({
      { role = "user", content = "look at this" },
    }, messages)
  end)

  it("strips older image payloads from in-memory API history", function()
    local messages = {
      {
        role = "user",
        content = {
          { type = "text", text = "first image" },
          { type = "image_url", image_url = { url = "data:image/png;base64,old" } },
        },
      },
      { role = "assistant", content = "ok" },
    }

    assert.is_true(session._strip_image_payloads_from_messages(messages))
    assert.same({ role = "user", content = "first image" }, messages[1])
    assert.same({ role = "assistant", content = "ok" }, messages[2])
  end)

  it("strips image payloads before plain follow-up requests", function()
    local messages = {
      {
        role = "user",
        content = {
          { type = "text", text = "image question" },
          { type = "image_url", image_url = { url = "data:image/png;base64,old" } },
        },
      },
    }

    session._strip_image_payloads_from_messages(messages)
    table.insert(messages, { role = "user", content = "plain follow-up" })

    assert.same({ role = "user", content = "image question" }, messages[1])
    assert.same({ role = "user", content = "plain follow-up" }, messages[2])
  end)

  it("inserts numbered image placeholders at the API input cursor", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Me:", "Compare these" })
    local win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      row = 1,
      col = 1,
      width = 40,
      height = 5,
      style = "minimal",
    })
    vim.api.nvim_win_set_cursor(win, { 2, 13 })

    local ok, err = pcall(function()
      session._insert_image_placeholder(buf, 0)
    end)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    vim.api.nvim_win_close(win, true)
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end

    assert.is_true(ok, err)
    assert.same({ "Me:", "Compare these <image0>" }, lines)
  end)

  it("normal-mode API paste inserts a numbered placeholder into the inline draft", function()
    local images = require("neocode.images")
    local old_save_clipboard = images.save_clipboard
    local old_delete_temp = images.delete_temp
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    local image_path = tmp .. "/pasted.png"
    vim.fn.writefile({ "fake image bytes" }, image_path)
    images.save_clipboard = function()
      return image_path, nil
    end
    images.delete_temp = function() end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Me:", "" })
    local win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      row = 1,
      col = 1,
      width = 40,
      height = 5,
      style = "minimal",
    })
    vim.api.nvim_win_set_cursor(win, { 2, 0 })
    local record = {
      id = "normal-paste-placeholder",
      bufnr = buf,
      pending_images_b64 = {},
    }

    local ok, err = pcall(function()
      session._paste_image_api(record, { data_dir = tmp })
    end)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    images.save_clipboard = old_save_clipboard
    images.delete_temp = old_delete_temp
    vim.api.nvim_win_close(win, true)
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    vim.fn.delete(tmp, "rf")

    assert.is_true(ok, err)
    assert.equals(1, #record.pending_images_b64)
    assert.same({ "Me:", "<image0>" }, lines)
  end)
end)

describe("session persistence", function()
  local tmp_dir = "/tmp/neocode_test_persist_" .. tostring(os.time())
  local config  = {
    data_dir = tmp_dir,
    adapters = {
      claude = {
        name          = "claude",
        session_store = true,
        launch_cmd    = function() return { cmd = "true", args = {}, cwd = "/tmp" } end,
        interrupt     = function() end,
        attach_image  = function() end,
      },
    },
  }

  before_each(function()
    session._reset()
    vim.fn.mkdir(tmp_dir, "p")
  end)

  after_each(function()
    vim.fn.delete(tmp_dir, "rf")
  end)

  it("_persist() writes sessions.json", function()
    local s = session._new_record("claude", "Persist me")
    session._add(s)
    session._persist(config)
    local path = tmp_dir .. "/sessions.json"
    assert.equals(1, vim.fn.filereadable(path))
  end)

  it("_persist() does not write runtime fields", function()
    local s    = session._new_record("claude", "No runtime")
    s.bufnr    = 99
    s.job_id   = 5
    session._add(s)
    session._persist(config)
    local f       = io.open(tmp_dir .. "/sessions.json")
    local content = f:read("*a")
    f:close()
    assert.is_falsy(content:find("bufnr"))
    assert.is_falsy(content:find("job_id"))
  end)

  it("_persist() includes status field", function()
    local s = session._new_record("claude", "Status test")
    session._add(s)
    session._persist(config)
    local f       = io.open(tmp_dir .. "/sessions.json")
    local content = f:read("*a")
    f:close()
    assert.is_truthy(content:find("status"))
  end)

  it("_persist() includes cwd for project-scoped API session resume", function()
    local s = session._new_record("claude", "Project scoped")
    s.cwd = "/tmp/project-root"
    session._add(s)
    session._persist(config)
    local all = session.load_all_from_disk(config)
    assert.equals("/tmp/project-root", all[1].cwd)
  end)

  it("auto-titles API sessions from the captured first user message", function()
    local cfg = {
      data_dir = tmp_dir,
      adapters = {
        ["local"] = { name = "local", type = "api", session_store = true },
      },
    }
    local s = session._new_record("local", "local 1")
    s.cwd = "/tmp/neocode-project"
    s.api_adapter = cfg.adapters["local"]
    s.messages = { { role = "user", content = "Can you analyze this project?" } }
    session._add(s)

    assert.is_true(session._auto_title_from_first_user_message(s, "Can you analyze this project?", cfg, true))

    local all = session.load_all_from_disk(cfg)
    assert.equals(1, #all)
    assert.equals("Can you analyze this project?", all[1].title)
    assert.equals("Can you analyze this project?", session._store_for_record(cfg, s).load_meta(s.id).title)
  end)

  it("_persist() writes private sessions.json", function()
    local s = session._new_record("claude", "Private metadata")
    session._add(s)
    session._persist(config)

    assert.equals("rw-------", vim.fn.getfperm(tmp_dir .. "/sessions.json"))
  end)

  it("_persist() skips sessions with session_store = false", function()
    local opencode_adapter = {
      name          = "opencode",
      session_store = false,
      launch_cmd    = function() return { cmd = "true", args = {}, cwd = "/tmp" } end,
      interrupt     = function() end,
      attach_image  = function() end,
    }
    local cfg = {
      data_dir = tmp_dir,
      adapters = { opencode = opencode_adapter },
    }
    local s = session._new_record("opencode", "OpenCode chat")
    session._add(s)
    session._persist(cfg)
    local f       = io.open(tmp_dir .. "/sessions.json")
    local content = f:read("*a")
    f:close()
    -- Should be an empty array since session_store = false
    assert.equals("[]", content)
  end)
end)

describe("session disk operations", function()
  local tmp_dir = "/tmp/neocode_test_disk_" .. tostring(os.time())
  local config  = { data_dir = tmp_dir, adapters = {} }

  before_each(function()
    session._reset()
    vim.fn.mkdir(tmp_dir, "p")
  end)

  after_each(function()
    vim.fn.delete(tmp_dir, "rf")
  end)

  it("load_all_from_disk() returns empty table when no file", function()
    local all = session.load_all_from_disk(config)
    assert.equals(0, #all)
  end)

  it("load_all_from_disk() discovers project-scoped API session metadata without sessions.json", function()
    local store = require("neocode.session_store").new({
      data_dir = tmp_dir,
      cwd = "/tmp/neocode-project",
    })
    store.save_meta({
      id = "layered-session",
      adapter = "local",
      title = "Neocode-Test",
      status = "active",
      created_at = 42,
      cwd = "/tmp/neocode-project",
    })
    store.save_messages("layered-session", { { role = "user", content = "hello" } })

    local all = session.load_all_from_disk({
      data_dir = tmp_dir,
      adapters = { ["local"] = { name = "local", type = "api", session_store = true } },
    })

    assert.equals(1, #all)
    assert.equals("layered-session", all[1].id)
    assert.equals("Neocode-Test", all[1].title)
    assert.equals("/tmp/neocode-project", all[1].cwd)
  end)

  it("load_all_from_disk() prefers layered API metadata over stale sessions.json entries", function()
    local f = io.open(tmp_dir .. "/sessions.json", "w")
    f:write(vim.fn.json_encode({
      { id = "same-session", adapter = "local", title = "local 1", status = "active", created_at = 1, cwd = "/tmp/old" },
    }))
    f:close()

    local store = require("neocode.session_store").new({
      data_dir = tmp_dir,
      cwd = "/tmp/new-project",
    })
    store.save_meta({
      id = "same-session",
      adapter = "local",
      title = "Neocode-Test",
      status = "active",
      created_at = 2,
      cwd = "/tmp/new-project",
    })

    local all = session.load_all_from_disk({
      data_dir = tmp_dir,
      adapters = { ["local"] = { name = "local", type = "api", session_store = true } },
    })

    assert.equals(1, #all)
    assert.equals("Neocode-Test", all[1].title)
    assert.equals("/tmp/new-project", all[1].cwd)
    assert.equals(2, all[1].created_at)
  end)

  it("load_all_from_disk() hides stale sessions for adapters with session_store = false", function()
    local f = io.open(tmp_dir .. "/sessions.json", "w")
    f:write(vim.fn.json_encode({
      { id = "llama-old", adapter = "llama", title = "Old local chat", status = "closed", created_at = 1 },
      { id = "claude-old", adapter = "claude", title = "Old Claude chat", status = "closed", created_at = 2 },
    }))
    f:close()

    local all = session.load_all_from_disk({
      data_dir = tmp_dir,
      adapters = {
        llama = { name = "llama", session_store = false },
        claude = { name = "claude", session_store = true },
      },
    })

    assert.equals(1, #all)
    assert.equals("claude-old", all[1].id)
  end)

  it("delete_from_disk() removes session by id", function()
    local s = session._new_record("claude", "Delete me")
    session._add(s)
    session._persist(config)
    session.delete_from_disk(s.id, config)
    local all = session.load_all_from_disk(config)
    assert.equals(0, #all)
  end)

  it("delete_from_disk() removes layered session data", function()
    local s = session._new_record("claude", "Delete layered")
    s.cwd = "/tmp/project-root"
    session._add(s)
    session._persist(config)
    session._save_api_messages(config, s, { { role = "user", content = "hello" } })
    local store = session._store_for_record(config, s)
    assert.equals(1, vim.fn.isdirectory(store.session_dir(s.id)))

    session.delete_from_disk(s.id, config)

    assert.equals(0, vim.fn.isdirectory(store.session_dir(s.id)))
  end)

  it("delete_from_disk() removes layered sessions discovered from their original cwd", function()
    local original = {
      id = "cross-cwd-delete",
      adapter = "local",
      title = "Delete cross cwd",
      status = "active",
      created_at = 3,
      cwd = "/tmp/original-project",
    }
    local store = require("neocode.session_store").new({ data_dir = tmp_dir, cwd = original.cwd })
    store.save_meta(original)
    store.save_messages(original.id, { { role = "user", content = "from original cwd" } })
    assert.equals(1, vim.fn.isdirectory(store.session_dir(original.id)))

    session.delete_from_disk(original.id, {
      data_dir = tmp_dir,
      adapters = { ["local"] = { name = "local", type = "api", session_store = true } },
    })

    assert.equals(0, vim.fn.isdirectory(store.session_dir(original.id)))
  end)

  it("rename_on_disk() updates session title", function()
    local s = session._new_record("claude", "Old name")
    session._add(s)
    session._persist(config)
    session.rename_on_disk(s.id, "New name", config)
    local all = session.load_all_from_disk(config)
    assert.equals("New name", all[1].title)
  end)

  it("rename_on_disk() updates layered session metadata", function()
    local s = session._new_record("claude", "Old name")
    s.cwd = "/tmp/project-root"
    session._add(s)
    session._persist(config)
    session._save_api_messages(config, s, { { role = "user", content = "hello" } })

    session.rename_on_disk(s.id, "New name", config)

    local meta = session._store_for_record(config, s).load_meta(s.id)
    assert.equals("New name", meta.title)
  end)

  it("rename_on_disk() updates layered sessions discovered from their original cwd", function()
    local original = {
      id = "cross-cwd-rename",
      adapter = "local",
      title = "Old cross cwd name",
      status = "active",
      created_at = 4,
      cwd = "/tmp/original-project",
    }
    local store = require("neocode.session_store").new({ data_dir = tmp_dir, cwd = original.cwd })
    store.save_meta(original)

    session.rename_on_disk(original.id, "New cross cwd name", {
      data_dir = tmp_dir,
      adapters = { ["local"] = { name = "local", type = "api", session_store = true } },
    })

    assert.equals("New cross cwd name", store.load_meta(original.id).title)
  end)
end)

describe("api session layered store integration", function()
  local tmp_dir
  local config

  before_each(function()
    session._reset()
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
    config = { data_dir = tmp_dir, adapters = {} }
  end)

  after_each(function()
    vim.fn.delete(tmp_dir, "rf")
  end)

  local function record()
    return {
      id = "sess-layered",
      adapter = "llama",
      title = "Layered session",
      created_at = 456,
      cwd = "/Users/example/project",
    }
  end

  it("saves and loads API messages from the project-scoped layered store", function()
    local r = record()
    local messages = {
      { role = "user", content = "hello" },
      { role = "assistant", content = "hi" },
    }

    session._save_api_messages(config, r, messages)

    assert.are.same(messages, session._load_api_messages(config, r))
    assert.equals(1, vim.fn.filereadable(session._store_for_record(config, r).session_dir(r.id) .. "/messages.json"))
  end)

  it("appends raw transcript events independently of prompt-ready messages", function()
    local r = record()

    session._append_transcript(config, r, { role = "user", content = "raw detail" })

    local transcript_path = session._store_for_record(config, r).session_dir(r.id) .. "/transcript.jsonl"
    local lines = vim.fn.readfile(transcript_path)
    assert.equals(1, #lines)
    assert.equals("raw detail", vim.fn.json_decode(lines[1]).content)
  end)

  it("saves compacted summaries without deleting transcript history", function()
    local r = record()
    session._append_transcript(config, r, { role = "user", content = "before compact" })

    session._save_api_summary(config, r, "Summary after compaction")

    local store = session._store_for_record(config, r)
    assert.equals("Summary after compaction", store.load_summary(r.id))
    local transcript = table.concat(vim.fn.readfile(store.session_dir(r.id) .. "/transcript.jsonl"), "\n")
    assert.is_truthy(transcript:find("before compact", 1, true))
  end)

  it("falls back to legacy llama history only when layered messages are missing", function()
    local r = record()
    local legacy = require("neocode.llama_session")
    legacy.save(tmp_dir .. "/llama", r.id, { { role = "user", content = "legacy" } })

    assert.equals("legacy", session._load_api_messages(config, r)[1].content)
  end)

  it("prefers layered messages over legacy llama history", function()
    local r = record()
    local legacy = require("neocode.llama_session")
    legacy.save(tmp_dir .. "/llama", r.id, { { role = "user", content = "legacy" } })
    session._save_api_messages(config, r, { { role = "user", content = "layered" } })

    assert.equals("layered", session._load_api_messages(config, r)[1].content)
  end)

  it("does not fall back to stale legacy history when layered messages are corrupt", function()
    local r = record()
    local legacy = require("neocode.llama_session")
    legacy.save(tmp_dir .. "/llama", r.id, { { role = "user", content = "legacy" } })

    local store = session._store_for_record(config, r)
    vim.fn.mkdir(store.session_dir(r.id), "p")
    vim.fn.writefile({ "not valid json" }, store.session_dir(r.id) .. "/messages.json")

    assert.are.same({}, session._load_api_messages(config, r))
  end)

  it("loads project-scoped messages using cwd from saved session metadata", function()
    local r = record()
    session._save_api_messages(config, r, { { role = "user", content = "from original cwd" } })

    local resumed = {
      id = r.id,
      adapter = r.adapter,
      title = r.title,
      created_at = r.created_at,
      cwd = r.cwd,
    }

    assert.equals("from original cwd", session._load_api_messages(config, resumed)[1].content)
  end)

  it("loads discovered layered API messages using the metadata cwd instead of current cwd", function()
    local r = record()
    session._save_api_messages(config, r, { { role = "user", content = "from original cwd" } })

    local discovered = session.load_all_from_disk({
      data_dir = tmp_dir,
      adapters = { llama = { name = "llama", type = "api", session_store = true } },
    })[1]

    assert.equals(r.cwd, discovered.cwd)
    assert.equals("from original cwd", session._load_api_messages(config, discovered)[1].content)
  end)

  it("resume_api uses persisted cwd when rebuilding an API session", function()
    local r = record()
    session._save_api_messages(config, r, { { role = "user", content = "from original cwd" } })

    local adapter = { name = "llama", type = "api", session_store = true }
    session.resume_api(adapter, {
      id = r.id,
      adapter = r.adapter,
      title = r.title,
      created_at = r.created_at,
      cwd = r.cwd,
    }, config)

    local resumed = session._get(r.id)
    assert.equals(r.cwd, resumed.cwd)
    assert.equals("from original cwd", resumed.messages[1].content)

    if resumed.bufnr and vim.api.nvim_buf_is_valid(resumed.bufnr) then
      vim.api.nvim_buf_delete(resumed.bufnr, { force = true })
    end
  end)
end)
