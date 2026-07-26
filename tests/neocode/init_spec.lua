local neocode = require("neocode")

describe("neocode.setup", function()
  it("raises error when adapter module is missing required fields", function()
    assert.has_error(function()
      neocode.setup({
        adapters = { fake = { name = "fake" } },
      })
    end)
  end)

  it("uses default data_dir when not specified", function()
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

  it("accepts valid config without error", function()
    local opencode = require("neocode.adapters.opencode")
    assert.has_no_error(function()
      neocode.setup({
        default_adapter = "opencode",
        adapters = { opencode = opencode },
      })
    end)
  end)

  it("validates the adapter contract for CLI adapters", function()
    assert.has_error(function()
      neocode.setup({
        adapters = {
          cli = {
            name = "cli",
            session_store = true,
          },
        },
      })
    end, "neocode: adapter 'cli' is missing required field 'launch_cmd'")
  end)

  it("registers global keymaps after setup", function()
    local opencode = require("neocode.adapters.opencode")
    neocode.setup({ adapters = { opencode = opencode } })
    local maps = vim.api.nvim_get_keymap("n")
    local found = false
    for _, m in ipairs(maps) do
      if m.desc == "NeoCode: launcher" then found = true end
    end
    assert.is_true(found)
  end)

  it("sets default adapter to opencode", function()
    local opencode = require("neocode.adapters.opencode")
    neocode.setup({ adapters = { opencode = opencode } })
    assert.equals("opencode", neocode._config.default_adapter)
  end)

  it("creates data and images directories", function()
    local tmp = vim.fn.tempname()
    local opencode = require("neocode.adapters.opencode")
    neocode.setup({
      data_dir = tmp .. "/neocode_data",
      adapters = { opencode = opencode },
    })
    assert.equals(1, vim.fn.isdirectory(tmp .. "/neocode_data"))
    assert.equals(1, vim.fn.isdirectory(tmp .. "/neocode_data/images"))
    vim.fn.delete(tmp, "rf")
  end)
end)
