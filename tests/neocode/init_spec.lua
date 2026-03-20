local neocode = require("neocode")

describe("neocode.setup", function()
  it("raises error when adapter module is missing", function()
    assert.has_error(function()
      neocode.setup({
        adapters = { fake = { name = "fake" } }, -- missing required fields
      })
    end)
  end)

  it("uses default data_dir when not specified", function()
    -- Use a dummy inline adapter that satisfies all required fields
    local dummy = {
      name          = "dummy",
      session_store = false,
      launch_cmd    = function() return { cmd = "true", args = {}, cwd = "/tmp" } end,
      interrupt     = function() end,
      attach_image  = function() end,
    }
    neocode.setup({ adapters = { dummy = dummy } })
    assert.is_not_nil(neocode._config.data_dir)
  end)
end)
