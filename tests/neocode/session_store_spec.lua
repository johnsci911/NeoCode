local session_store = require("neocode.session_store")

describe("session_store", function()
  local tmp_dir
  local store

  before_each(function()
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
    store = session_store.new({ data_dir = tmp_dir, cwd = "/Users/example/project" })
  end)

  after_each(function()
    vim.fn.delete(tmp_dir, "rf")
  end)

  it("stores session data under a project-scoped global directory", function()
    local meta = { id = "sess-1", adapter = "pi", title = "Pi Session", created_at = 123 }

    store.save_meta(meta)

    local path = store.session_dir("sess-1") .. "/meta.json"
    assert.equals(1, vim.fn.filereadable(path))
    assert.is_truthy(path:find(tmp_dir .. "/projects/", 1, true))
    assert.is_truthy(path:find("/sessions/sess-1/meta.json", 1, true))
  end)

  it("rejects unsafe session ids before building paths", function()
    assert.is_false(session_store.is_valid_session_id("../escape"))
    assert.is_false(session_store.is_valid_session_id("nested/session"))
    assert.is_false(session_store.is_valid_session_id(""))
    assert.is_true(session_store.is_valid_session_id("neocode_123_1"))

    local ok = pcall(function()
      store.save_meta({ id = "../escape", title = "bad" })
    end)
    assert.is_false(ok)
  end)

  it("deletes all files for a stored session", function()
    store.save_meta({ id = "sess-1", adapter = "pi", title = "Test", created_at = 123 })

    store.delete_session("sess-1")

    assert.equals(0, vim.fn.isdirectory(store.session_dir("sess-1")))
  end)

  it("creates private session directories and files", function()
    store.save_meta({ id = "sess-1", adapter = "pi", title = "Secret", created_at = 123 })

    assert.equals("rwx------", vim.fn.getfperm(store.session_dir("sess-1")))
    assert.equals("rw-------", vim.fn.getfperm(store.session_dir("sess-1") .. "/meta.json"))
  end)

  it("loads and saves metadata correctly", function()
    local meta = { id = "sess-1", adapter = "opencode", title = "Load Test", created_at = 456 }
    store.save_meta(meta)

    local loaded = store.load_meta("sess-1")
    assert.equals("opencode", loaded.adapter)
    assert.equals("Load Test", loaded.title)
    assert.equals(456, loaded.created_at)
  end)

  it("returns nil when loading non-existent meta", function()
    assert.is_nil(store.load_meta("nonexistent"))
  end)
end)
