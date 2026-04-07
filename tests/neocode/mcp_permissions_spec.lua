-- tests/neocode/mcp_permissions_spec.lua
local perms = require("neocode.mcp_permissions")

describe("mcp_permissions", function()
  before_each(function()
    perms._reset()
  end)

  it("returns nil for unknown tool", function()
    assert.is_nil(perms.check("server", "tool"))
  end)

  it("grant allowed_once is consumed after check_and_consume", function()
    perms.grant("server", "tool", "allowed_once")
    assert.equals("allowed_once", perms.check("server", "tool"))
    perms.consume("server", "tool")
    assert.is_nil(perms.check("server", "tool"))
  end)

  it("grant allowed_session persists across checks", function()
    perms.grant("server", "tool", "allowed_session")
    assert.equals("allowed_session", perms.check("server", "tool"))
    perms.consume("server", "tool")
    assert.equals("allowed_session", perms.check("server", "tool"))
  end)

  it("grant allowed_always persists across checks", function()
    perms.grant("server", "tool", "allowed_always")
    assert.equals("allowed_always", perms.check("server", "tool"))
    perms.consume("server", "tool")
    assert.equals("allowed_always", perms.check("server", "tool"))
  end)

  it("is_allowed returns true for granted permissions", function()
    perms.grant("server", "tool", "allowed_session")
    assert.is_true(perms.is_allowed("server", "tool"))
  end)

  it("is_allowed returns false for unknown tools", function()
    assert.is_false(perms.is_allowed("server", "tool"))
  end)
end)

describe("mcp_permissions persistence", function()
  local tmp_dir = "/tmp/neocode_test_perms_" .. tostring(os.time())

  before_each(function()
    perms._reset()
    vim.fn.mkdir(tmp_dir, "p")
  end)

  after_each(function()
    vim.fn.delete(tmp_dir, "rf")
  end)

  it("save writes only allowed_always to disk", function()
    perms.grant("srv1", "tool1", "allowed_always")
    perms.grant("srv2", "tool2", "allowed_session")
    perms.save({ data_dir = tmp_dir })

    local path = tmp_dir .. "/mcp_permissions.json"
    assert.equals(1, vim.fn.filereadable(path))

    local f = io.open(path)
    local content = f:read("*a")
    f:close()
    assert.is_truthy(content:find("srv1"))
    assert.is_falsy(content:find("srv2"))
  end)

  it("load restores allowed_always from disk", function()
    perms.grant("srv1", "tool1", "allowed_always")
    perms.save({ data_dir = tmp_dir })

    perms._reset()
    perms.load({ data_dir = tmp_dir })
    assert.equals("allowed_always", perms.check("srv1", "tool1"))
  end)
end)
