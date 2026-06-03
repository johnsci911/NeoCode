local memory = require("neocode.memory")

describe("memory", function()
  local tmp_dir
  local project

  before_each(function()
    tmp_dir = vim.fn.tempname()
    project = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
    vim.fn.mkdir(project, "p")
  end)

  after_each(function()
    vim.fn.delete(tmp_dir, "rf")
    vim.fn.delete(project, "rf")
  end)

  it("stores project-scoped memory under NeoCode data dir, not project tree", function()
    local store = memory.new({ data_dir = tmp_dir, cwd = project })

    store.save({ text = "User prefers Radix for shadcn." })

    assert.equals(1, vim.fn.filereadable(store.path()))
    assert.is_truthy(store.path():find(tmp_dir .. "/memory/projects/", 1, true))
    assert.equals(0, vim.fn.isdirectory(project .. "/.neocode"))
  end)

  it("loads approved memory entries in insertion order", function()
    local store = memory.new({ data_dir = tmp_dir, cwd = project })

    store.save({ text = "First preference" })
    store.save({ text = "Second preference" })

    local entries = store.load()

    assert.equals("First preference", entries[1].text)
    assert.equals("Second preference", entries[2].text)
  end)

  it("builds a prompt context from saved memory", function()
    local store = memory.new({ data_dir = tmp_dir, cwd = project })
    store.save({ text = "Use pnpm." })

    local context = store.context_message()

    assert.equals("system", context.role)
    assert.is_truthy(context.content:find("Use pnpm.", 1, true))
    assert.is_true(context._is_memory_context)
  end)
end)
