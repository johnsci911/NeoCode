local input = require("neocode.input")

describe("input popup", function()
  local original_notify

  before_each(function()
    original_notify = vim.notify
    vim.notify = function() end
  end)

  after_each(function()
    vim.notify = original_notify
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].filetype == "markdown" and vim.bo[buf].bufhidden == "wipe" then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
  end)

  it("maps cancel in insert mode so Escape closes instead of only leaving insert mode", function()
    input.open({ job_id = 123 }, {})
    local buf = vim.api.nvim_get_current_buf()
    local win = vim.api.nvim_get_current_win()

    local insert_escape = vim.fn.maparg("<Esc>", "i", false, true)
    local normal_escape = vim.fn.maparg("<Esc>", "n", false, true)

    assert.equals(buf, vim.api.nvim_get_current_buf())
    assert.equals(1, insert_escape.buffer)
    assert.equals(1, normal_escape.buffer)
    assert.is_function(insert_escape.callback)
    assert.is_function(normal_escape.callback)

    insert_escape.callback()

    assert.is_false(vim.api.nvim_win_is_valid(win))
  end)
end)
