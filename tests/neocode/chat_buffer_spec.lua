-- tests/neocode/chat_buffer_spec.lua
describe("chat_buffer", function()
  local chat_buffer = require("neocode.chat_buffer")

  it("renders messages as simple markdown blocks", function()
    local messages = {
      { role = "user", content = "What is 2+2?" },
      { role = "assistant", content = "The answer is **4**." },
    }
    local lines = chat_buffer.render_lines(messages)
    assert.is_true(#lines > 0)
    local found_user = false
    local found_assistant = false
    for _, line in ipairs(lines) do
      if line == "━━━━━━ You ━━━━━━" then found_user = true end
      if line == "━━━ Assistant ━━━" then found_assistant = true end
    end
    assert.is_true(found_user)
    assert.is_true(found_assistant)
  end)

  it("keeps fenced code lines unprefixed inside boxed blocks for syntax highlighting", function()
    local lines = chat_buffer.render_lines({
      { role = "assistant", content = table.concat({
        "Here is Lua:",
        "```lua",
        "local M = {}",
        "```",
      }, "\n") },
    })

    local text = table.concat(lines, "\n")
    assert.is_truthy(text:find("━━━ Assistant ━━━", 1, true))
    assert.is_truthy(text:find("```lua", 1, true))
    assert.is_truthy(text:find("\nlocal M = {}\n", 1, true))
    assert.is_falsy(text:find("│ local M = {}", 1, true))
  end)

  it("renders model-escaped fence lines as markdown code fences", function()
    local lines = chat_buffer.render_lines({
      { role = "assistant", content = table.concat({
        "Tip:",
        "\\```python",
        "print('hello')",
        "\\```",
      }, "\n") },
    })

    local text = table.concat(lines, "\n")
    assert.is_truthy(text:find("```python", 1, true))
    assert.is_truthy(text:find("\nprint('hello')\n", 1, true))
    assert.is_falsy(text:find("\\```python", 1, true))
  end)

  it("uses simple horizontal separators without box corners or side borders", function()
    local lines = chat_buffer.render_lines({
      { role = "assistant", content = "Hello!\n\nHow can I help?" },
    })

    local text = table.concat(lines, "\n")
    assert.is_truthy(text:find("━━━ Assistant ━━━", 1, true))
    assert.is_falsy(text:find("╭", 1, true))
    assert.is_falsy(text:find("╰", 1, true))
    assert.is_truthy(text:find("\nHello!\n", 1, true))
    assert.is_truthy(text:find("\nHow can I help?\n", 1, true))
    assert.is_falsy(text:find("│", 1, true))
  end)

  it("uses role labels only on opening separators", function()
    local lines = chat_buffer.render_lines({
      { role = "assistant", content = "Hello!" },
    }, { width = 120 })

    assert.equals("━━━ Assistant ━━━", lines[1])
    assert.equals("━━━━━━━━━━━━━━━━━━", lines[#lines])
  end)

  it("reports content ranges for message separators", function()
    local lines, blocks = chat_buffer.render_lines({
      { role = "user", content = "hello" },
      { role = "assistant", content = "hi" },
    }, { metadata = true })

    assert.is_true(#lines > 0)
    assert.equals(2, #blocks)
    assert.equals("You", blocks[1].label)
    assert.equals("Assistant", blocks[2].label)
    assert.is_true(blocks[1].content_start <= blocks[1].content_end)
  end)

  it("refresh keeps markdown filetype and highlights separators", function()
    local buf = vim.api.nvim_create_buf(false, true)
    chat_buffer.refresh(buf, { { role = "assistant", content = "```lua\nlocal M = {}\n```" } })

    assert.equals("markdown", vim.bo[buf].filetype)
    local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
    assert.is_true(#marks > 0)
    for _, mark in ipairs(marks) do
      assert.is_nil(mark[4].virt_text)
    end

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("renders empty messages as an editable local input draft", function()
    local lines = chat_buffer.render_lines({})
    assert.are.same({
      "Me:",
      "",
      "Press <C-s>, <C-CR>, or <M-CR> to send",
    }, lines)
  end)

  it("renders chat context and thinking status above the draft", function()
    local lines = chat_buffer.render_lines({}, {
      status = {
        context_size = 24576,
        context_used = 12288,
        thinking_available = true,
        thinking_mode = "low",
      },
    })

    assert.are.same({
      "Context: 12288 / 24576 | 50% · Thinking: low",
      "",
      "Me:",
      "",
      "Press <C-s>, <C-CR>, or <M-CR> to send",
    }, lines)
  end)

  it("does not render thinking status when thinking is unavailable", function()
    local lines = chat_buffer.render_lines({}, {
      status = {
        context_size = 32768,
        context_used = 16192,
        thinking_available = false,
        thinking_mode = "low",
      },
    })

    assert.are.same({
      "Context: 16192 / 32768 | 49%",
      "",
      "Me:",
      "",
      "Press <C-s>, <C-CR>, or <M-CR> to send",
    }, lines)
  end)

  it("omits the status line when no chat metadata is available", function()
    local lines = chat_buffer.render_lines({}, {
      status = {
        thinking_available = false,
        thinking_mode = "low",
      },
    })

    assert.are.same({
      "Me:",
      "",
      "Press <C-s>, <C-CR>, or <M-CR> to send",
    }, lines)
  end)

  it("does not treat the empty input draft as a message block", function()
    local lines, blocks = chat_buffer.render_lines({}, { metadata = true })

    assert.equals("Me:", lines[1])
    assert.are.same({}, blocks)
  end)

  it("renders a bottom draft prompt after existing messages when requested", function()
    local lines = chat_buffer.render_lines({
      { role = "user", content = "Hi" },
      { role = "assistant", content = "Hello" },
    }, { draft = true })

    assert.equals("Me:", lines[#lines - 2])
    assert.equals("", lines[#lines - 1])
    assert.equals("Press <C-s>, <C-CR>, or <M-CR> to send", lines[#lines])
  end)

  it("includes image indicator for vision messages", function()
    local messages = {
      { role = "user", content = {
        { type = "text", text = "What is this?" },
        { type = "image_url", image_url = { url = "data:image/png;base64,abc" } },
      }},
    }
    local lines = chat_buffer.render_lines(messages)
    local found_image = false
    for _, line in ipairs(lines) do
      if line:match("%[image%]") then found_image = true end
    end
    assert.is_true(found_image)
  end)

  it("renders tool calls as summary lines", function()
    local cb = require("neocode.chat_buffer")
    local messages = {
      { role = "user", content = "Read my config" },
      {
        role = "assistant",
        content = "Let me check that.",
        tool_calls = {
          { id = "1", type = "function", ["function"] = { name = "filesystem__read_file", arguments = '{"path":"init.lua"}' } },
        },
      },
      { role = "tool", tool_call_id = "1", content = "-- file contents --" },
      { role = "assistant", content = "Here is your config." },
    }
    local lines = cb.render_lines(messages)
    local text = table.concat(lines, "\n")
    assert.is_truthy(text:find("read_file"))
    -- Should show read icon for read operations
    assert.is_truthy(text:find("📖"))
    -- Should show file path directly
    assert.is_truthy(text:find("init.lua"))
    -- Tool role messages should be hidden
    assert.is_falsy(text:find("file contents"))
  end)

  it("renders tool calls when assistant content is nil", function()
    local lines = chat_buffer.render_lines({
      {
        role = "assistant",
        content = nil,
        tool_calls = {
          { id = "1", type = "function", ["function"] = { name = "neocode__list_directory", arguments = '{"path":"."}' } },
        },
      },
    })

    local text = table.concat(lines, "\n")
    assert.is_truthy(text:find("list_directory", 1, true))
  end)

  it("renders plain tool result previews without crashing", function()
    local lines = chat_buffer.render_lines({
      {
        role = "assistant",
        content = "I'll inspect that.",
        tool_calls = {
          {
            id = "1",
            type = "function",
            ["function"] = { name = "neocode__list_directory", arguments = '{"path":"."}' },
            _status = "done",
            _result_preview = "README.md\nlua\ntests",
          },
        },
      },
    })

    local text = table.concat(lines, "\n")
    assert.is_truthy(text:find("README.md", 1, true))
    assert.is_truthy(text:find("lua", 1, true))
  end)

  it("shows correct icons for different tool actions", function()
    local cb = require("neocode.chat_buffer")
    local messages = {
      {
        role = "assistant",
        content = "",
        tool_calls = {
          { id = "1", type = "function", ["function"] = { name = "fs__write_file", arguments = '{"path":"out.txt"}' } },
          { id = "2", type = "function", ["function"] = { name = "sh__run_command", arguments = '{"command":"ls"}' } },
        },
      },
    }
    local lines = cb.render_lines(messages)
    local text = table.concat(lines, "\n")
    -- Write operations get edit icon
    assert.is_truthy(text:find("✏️"))
    -- Run/exec operations get lightning icon
    assert.is_truthy(text:find("⚡"))
  end)
end)
