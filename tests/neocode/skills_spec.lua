local skills = require("neocode.skills")

describe("skills", function()
  local tmp_dir

  before_each(function()
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
  end)

  after_each(function()
    vim.fn.delete(tmp_dir, "rf")
  end)

  it("stores skills under NeoCode data dir", function()
    local store = skills.new({ data_dir = tmp_dir })

    store.save("laravel", "Use Laravel conventions.")

    assert.equals(1, vim.fn.filereadable(tmp_dir .. "/skills/laravel.md"))
  end)

  it("loads only manually selected skills", function()
    local store = skills.new({ data_dir = tmp_dir })
    store.save("laravel", "Use Laravel conventions.")
    store.save("react", "Use React conventions.")

    local selected = store.load_selected({ "react" })

    assert.equals(1, #selected)
    assert.equals("react", selected[1].name)
    assert.equals("Use React conventions.", selected[1].content)
  end)

  it("builds a system context message for selected skills", function()
    local store = skills.new({ data_dir = tmp_dir })
    store.save("laravel", "Use Laravel conventions.")

    local msg = store.context_message({ "laravel" })

    assert.equals("system", msg.role)
    assert.is_true(msg._is_skills_context)
    assert.is_truthy(msg.content:find("Skill: laravel", 1, true))
  end)
end)
