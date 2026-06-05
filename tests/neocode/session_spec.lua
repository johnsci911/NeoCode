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

      assert.same({ "neocode__read_file", "neocode__list_directory", "neocode__search_files", "neocode__run_shell_command" }, names)
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

      assert.same({ "neocode__read_file", "neocode__list_directory", "neocode__search_files", "neocode__run_shell_command" }, names)
    end)

    it("keeps README update prompts on local tools", function()
      local tools = session._build_project_tools("update the README with setup notes", "/project")
      local names = {}
      for _, schema in ipairs(tools or {}) do
        table.insert(names, schema["function"].name)
      end

      assert.same({ "neocode__read_file", "neocode__list_directory", "neocode__search_files", "neocode__run_shell_command" }, names)
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
      local record = {
        api_adapter = {
          config = { context_size = 32768 },
        },
      }
      local config = {
        auto_compact = { context_size = 16384 },
      }

      assert.equals(24576, session._auto_compact_context_size(config, record, { context_size = 24576 }))
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

    it("detects when prompt usage crosses configured threshold", function()
      local record = {
        api_adapter = {
          config = { context_size = 24576 },
        },
      }
      local config = {
        auto_compact = { enabled = true, threshold = 0.8 },
      }

      assert.is_false(session._should_auto_compact(config, record, { prompt_tokens = 19000 }))
      assert.is_true(session._should_auto_compact(config, record, { prompt_tokens = 20000 }))
    end)

    it("does not compact when disabled or already compacting", function()
      local record = {
        _auto_compact_running = true,
        api_adapter = { config = { context_size = 24576 } },
      }

      assert.is_false(session._should_auto_compact({ auto_compact = { enabled = true } }, record, { prompt_tokens = 24576 }))
      record._auto_compact_running = false
      assert.is_false(session._should_auto_compact({ auto_compact = { enabled = false } }, record, { prompt_tokens = 24576 }))
    end)

    it("marks the next turn for compaction after a high-context response", function()
      local record = {
        api_adapter = { config = { context_size = 24576, base_url = "http://127.0.0.1:8080", model = "local" } },
      }
      local config = {
        auto_compact = { enabled = true, threshold = 0.8 },
      }

      assert.is_true(session._mark_auto_compact_if_needed(config, record, { prompt_tokens = 20000 }))
      assert.is_true(record._auto_compact_pending)
      assert.equals(20000, record._auto_compact_last_usage.prompt_tokens)
      assert.equals(24576, record._auto_compact_last_usage.context_size)
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
        opts.on_stdout(1, {
          vim.fn.json_encode({
            choices = {
              { message = { content = "Compacted summary of the old conversation." } },
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
          { role = "assistant", content = "Here is a summary of our conversation:\n\nCompacted summary of the old conversation." },
          { role = "user", content = "recent question" },
          { role = "assistant", content = "recent answer" },
        }, record.messages)
        assert.is_nil(record._auto_compact_last_usage)
        assert.is_false(record._auto_compact_pending)
        assert.is_false(record._auto_compact_running)
        local saved = session._load_api_messages(config, record)
        assert.equals("Here is a summary of our conversation:\n\nCompacted summary of the old conversation.", saved[2].content)
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

  it("_all() returns all sessions", function()
    session._add(session._new_record("claude", "A"))
    session._add(session._new_record("claude", "B"))
    assert.equals(2, #session._all())
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
