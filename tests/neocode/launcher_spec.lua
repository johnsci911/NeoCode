local launcher = require("neocode.launcher")

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
end)
