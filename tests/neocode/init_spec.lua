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

  it("accepts valid config without error", function()
    local claude = require("neocode.adapters.claude")
    assert.has_no_error(function()
      neocode.setup({
        default_adapter = "claude",
        adapters = { claude = claude },
      })
    end)
  end)

  it("validates claude adapter fields", function()
    local claude = require("neocode.adapters.claude")
    assert.equals("claude", claude.name)
    assert.is_function(claude.launch_cmd)
    assert.is_function(claude.interrupt)
    assert.is_function(claude.attach_image)
    assert.is_boolean(claude.session_store)
  end)

  it("claude launch_cmd returns a table with required keys", function()
    local claude = require("neocode.adapters.claude")
    local spec = claude.launch_cmd({ cwd = "/tmp" })
    assert.equals("claude", spec.cmd)
    assert.is_table(spec.args)
    assert.equals("/tmp", spec.cwd)
  end)

  it("registers global keymaps after setup", function()
    local claude = require("neocode.adapters.claude")
    neocode.setup({ adapters = { claude = claude } })
    -- Check keymap exists (Neovim API)
    local maps = vim.api.nvim_get_keymap("n")
    local found = false
    for _, m in ipairs(maps) do
      if m.lhs == "\\aiC" or m.lhs == "<leader>aiC" then found = true end
    end
    assert.is_true(found)
  end)
end)
