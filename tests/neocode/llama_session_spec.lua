-- tests/neocode/llama_session_spec.lua
describe("llama_session", function()
  local llama_session = require("neocode.llama_session")
  local tmp_dir

  before_each(function()
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
  end)

  after_each(function()
    vim.fn.delete(tmp_dir, "rf")
  end)

  it("saves and loads conversation history", function()
    local messages = {
      { role = "user", content = "Hello" },
      { role = "assistant", content = "Hi there!" },
    }
    llama_session.save(tmp_dir, "test-session", messages)
    local loaded = llama_session.load(tmp_dir, "test-session")
    assert.are.same(messages, loaded)
  end)

  it("returns empty table for non-existent session", function()
    local loaded = llama_session.load(tmp_dir, "no-such-session")
    assert.are.same({}, loaded)
  end)

  it("lists saved sessions", function()
    llama_session.save(tmp_dir, "sess-1", { { role = "user", content = "a" } })
    llama_session.save(tmp_dir, "sess-2", { { role = "user", content = "b" } })
    local list = llama_session.list(tmp_dir)
    table.sort(list)
    assert.are.same({ "sess-1", "sess-2" }, list)
  end)

  it("deletes a session", function()
    llama_session.save(tmp_dir, "sess-del", { { role = "user", content = "x" } })
    llama_session.delete(tmp_dir, "sess-del")
    local loaded = llama_session.load(tmp_dir, "sess-del")
    assert.are.same({}, loaded)
  end)
end)
