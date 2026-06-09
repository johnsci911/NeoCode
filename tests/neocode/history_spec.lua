local history = require("neocode.history")
local session = require("neocode.session")

describe("history picker entries", function()
  before_each(function()
    session._reset()
  end)

  it("includes active CLI sessions even without messages", function()
    local record = session._new_record("opencode", "OpenCode active")
    record.bufnr = vim.api.nvim_create_buf(false, true)
    session._add(record)

    local entries = history._build_entries({ data_dir = vim.fn.tempname(), adapters = {} })

    vim.api.nvim_buf_delete(record.bufnr, { force = true })
    assert.equals(1, #entries)
    assert.equals(record.id, entries[1].id)
    assert.equals("active", entries[1].status)
  end)

  it("keeps empty API sessions out of history", function()
    local record = session._new_record("local", "Empty API")
    record.messages = {}
    session._add(record)

    local entries = history._build_entries({ data_dir = vim.fn.tempname(), adapters = {} })

    assert.equals(0, #entries)
  end)
end)
