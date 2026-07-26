local launcher = require("neocode.launcher")

describe("launcher", function()
  it("labels OpenCode distinctly", function()
    local entries = launcher._entries({
      adapters = {
        opencode = { name = "opencode" },
      },
    })

    local labels = {}
    for _, entry in ipairs(entries) do
      labels[entry.name] = entry.display
    end

    assert.equals("  OpenCode", labels.opencode)
  end)

  it("labels Pi distinctly", function()
    local entries = launcher._entries({
      adapters = {
        pi = { name = "pi" },
      },
    })

    local labels = {}
    for _, entry in ipairs(entries) do
      labels[entry.name] = entry.display
    end

    assert.equals("  Pi", labels.pi)
  end)

  it("shows unknown adapters with their name prefixed by two spaces", function()
    local entries = launcher._entries({
      adapters = {
        custom = { name = "custom" },
      },
    })

    local labels = {}
    for _, entry in ipairs(entries) do
      labels[entry.name] = entry.display
    end

    assert.equals("  custom", labels.custom)
  end)

  it("sorts adapters alphabetically", function()
    local entries = launcher._entries({
      adapters = {
        pi = { name = "pi" },
        opencode = { name = "opencode" },
        custom = { name = "custom" },
      },
    })

    assert.equals("custom", entries[1].name)
    assert.equals("opencode", entries[2].name)
    assert.equals("pi", entries[3].name)
  end)

  it("returns empty list when no adapters configured", function()
    local entries = launcher._entries({ adapters = {} })
    assert.equals(0, #entries)
  end)
end)
