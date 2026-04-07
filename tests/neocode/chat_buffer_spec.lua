-- tests/neocode/chat_buffer_spec.lua
describe("chat_buffer", function()
  local chat_buffer = require("neocode.chat_buffer")

  it("renders messages as markdown", function()
    local messages = {
      { role = "user", content = "What is 2+2?" },
      { role = "assistant", content = "The answer is **4**." },
    }
    local lines = chat_buffer.render_lines(messages)
    assert.is_true(#lines > 0)
    local found_user = false
    local found_assistant = false
    for _, line in ipairs(lines) do
      if line:match("^### You") then found_user = true end
      if line:match("^### Assistant") then found_assistant = true end
    end
    assert.is_true(found_user)
    assert.is_true(found_assistant)
  end)

  it("renders empty messages as empty", function()
    local lines = chat_buffer.render_lines({})
    assert.are.same({}, lines)
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
    -- Tool role messages should be hidden
    assert.is_falsy(text:find("file contents"))
  end)
end)
