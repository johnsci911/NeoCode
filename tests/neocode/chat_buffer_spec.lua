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
end)
