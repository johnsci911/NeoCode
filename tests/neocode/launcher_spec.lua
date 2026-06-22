local launcher = require("neocode.launcher")
local neocode = require("neocode")

describe("launcher", function()
  it("labels NeoCode Local distinctly from Continue/Llama", function()
    local entries = launcher._entries({
      adapters = {
        llama = { name = "llama" },
        ["local"] = { name = "local", type = "api" },
      },
    })

    local labels = {}
    for _, entry in ipairs(entries) do
      labels[entry.name] = entry.display
    end

    assert.equals("  NeoCode Local", labels["local"])
    assert.equals("  Llama (Continue)", labels.llama)
  end)

  it("labels OpenAI-backed NeoCode adapters in the launcher", function()
    local entries = launcher._entries({
      adapters = {
        openai = { name = "openai", type = "api", config = { provider = "openai" } },
      },
    })

    local labels = {}
    for _, entry in ipairs(entries) do
      labels[entry.name] = entry.display
    end

    assert.equals("  NeoCode OpenAI", labels.openai)
  end)

  it("shows NeoCode Local after default setup even when user config only registers Claude", function()
    neocode.setup({
      adapters = {
        claude = require("neocode.adapters.claude"),
      },
    })

    local labels = {}
    for _, entry in ipairs(launcher._entries(neocode._config)) do
      labels[entry.name] = entry.display
    end

    assert.equals("  NeoCode Local", labels["local"])
    assert.equals("  NeoCode OpenAI", labels.openai)
  end)

  it("self-heals stale launcher configs that do not include built-in NeoCode API adapters", function()
    local stale_config = {
      adapters = {
        claude = require("neocode.adapters.claude"),
      },
    }

    local labels = {}
    for _, entry in ipairs(launcher._entries(stale_config)) do
      labels[entry.name] = entry.display
    end

    assert.equals("  NeoCode Local", labels["local"])
    assert.equals("  NeoCode OpenAI", labels.openai)
    assert.is_table(stale_config.adapters["local"])
    assert.is_table(stale_config.adapters.openai)
  end)
end)
