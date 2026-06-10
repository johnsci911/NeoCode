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

  it("paste() appends pasted images as ordered pending temp images", function()
    local dir = "/tmp/neocode_test_images/session_replace"
    vim.fn.mkdir(dir, "p")
    local old_path = dir .. "/old.png"
    local new_path = dir .. "/new.png"
    vim.fn.writefile({ "old" }, old_path)
    vim.fn.writefile({ "new" }, new_path)

    local original_save_clipboard = images.save_clipboard
    images.save_clipboard = function()
      return new_path, nil
    end
    local attached
    local adapter = {
      attach_image = function(_, path)
        attached = path
      end,
    }
    local session = { id = "session_replace", pending_images = { old_path } }

    local ok, err = pcall(function()
      images.paste(adapter, session, { data_dir = "/tmp/neocode_test_images" })
    end)

    images.save_clipboard = original_save_clipboard

    assert.is_true(ok, err)
    assert.equals(1, vim.fn.filereadable(old_path))
    assert.equals(new_path, attached)
    assert.same({ old_path, new_path }, session.pending_images)
    assert.equals(new_path, session.pending_image)
    vim.fn.delete(dir, "rf")
  end)
end)
