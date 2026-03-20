local images = require("neocode.images")

describe("images", function()
  it("detect_tool() returns a string or nil", function()
    local tool = images.detect_tool()
    -- Either found a tool or nil — both valid depending on the machine
    assert.is_true(tool == nil or type(tool) == "string")
  end)

  it("temp_path() returns a path string inside data_dir containing session_id", function()
    local path = images.temp_path("/tmp/neocode_test", "session_abc")
    assert.truthy(path:find("session_abc"))
    assert.truthy(path:find("%.png$"))
  end)

  it("cleanup_session() removes the session image folder", function()
    local dir = "/tmp/neocode_test_images/session_xyz"
    vim.fn.mkdir(dir, "p")
    assert.equals(1, vim.fn.isdirectory(dir))
    images.cleanup_session("/tmp/neocode_test_images", "session_xyz")
    assert.equals(0, vim.fn.isdirectory(dir))
  end)
end)
