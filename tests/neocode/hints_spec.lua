local hints = require("neocode.hints")

describe("hints overlay", function()
  before_each(function()
    vim.o.lines   = 40
    vim.o.columns = 120
    hints._force_close()
  end)

  after_each(function()
    hints._force_close()
  end)

  it("is closed by default", function()
    assert.is_false(hints._is_open())
  end)

  it("toggle() opens the overlay", function()
    hints.toggle({})
    assert.is_true(hints._is_open())
  end)

  it("toggle() twice closes the overlay", function()
    hints.toggle({})
    hints.toggle({})
    assert.is_false(hints._is_open())
  end)

  it("_force_close() closes without error when already closed", function()
    assert.has_no_error(function()
      hints._force_close()
    end)
  end)
end)
