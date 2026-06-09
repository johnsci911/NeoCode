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

  it("opens session history for /session instead of sending to the CLI", function()
    local old_history = package.loaded["neocode.history"]
    local old_chansend = vim.fn.chansend
    local picked_config = nil
    local sent = false
    package.loaded["neocode.history"] = {
      pick = function(config)
        picked_config = config
      end,
    }
    vim.fn.chansend = function()
      sent = true
    end
    local session_record = {
      job_id = 42,
      bufnr = vim.api.nvim_create_buf(false, true),
    }
    local config = { data_dir = vim.fn.tempname() }

    local ok, err = pcall(function()
      input.open(session_record, config)
      local buf = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "/session" })
      local send_map = vim.fn.maparg("<C-s>", "n", false, true)
      assert.equals(1, send_map.buffer)
      assert.is_function(send_map.callback)
      send_map.callback()
      assert.equals(config, picked_config)
      assert.is_false(sent)
    end)

    package.loaded["neocode.history"] = old_history
    vim.fn.chansend = old_chansend
    if session_record.bufnr and vim.api.nvim_buf_is_valid(session_record.bufnr) then
      vim.api.nvim_buf_delete(session_record.bufnr, { force = true })
    end
    assert.is_true(ok, err)
  end)
end)
