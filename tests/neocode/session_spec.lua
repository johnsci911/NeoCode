local session = require("neocode.session")

describe("session", function()
  before_each(function()
    session._reset()  -- clear in-memory state between tests
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

  it("_persist() includes session_uuid and status", function()
    local s = session._new_record("claude", "UUID test")
    session._add(s)
    session._persist(config)
    local f       = io.open(tmp_dir .. "/sessions.json")
    local content = f:read("*a")
    f:close()
    assert.is_truthy(content:find("session_uuid"))
    assert.is_truthy(content:find("status"))
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

  it("delete_from_disk() removes session by id", function()
    local s = session._new_record("claude", "Delete me")
    session._add(s)
    session._persist(config)
    session.delete_from_disk(s.id, config)
    local all = session.load_all_from_disk(config)
    assert.equals(0, #all)
  end)

  it("rename_on_disk() updates session title", function()
    local s = session._new_record("claude", "Old name")
    session._add(s)
    session._persist(config)
    session.rename_on_disk(s.id, "New name", config)
    local all = session.load_all_from_disk(config)
    assert.equals("New name", all[1].title)
  end)
end)
