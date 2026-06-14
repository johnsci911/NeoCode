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

  it("maps delete in both normal and insert mode for the telescope picker", function()
    local old_modules = {
      pickers = package.loaded["telescope.pickers"],
      finders = package.loaded["telescope.finders"],
      config = package.loaded["telescope.config"],
      actions = package.loaded["telescope.actions"],
      action_state = package.loaded["telescope.actions.state"],
    }
    local mapped = {}
    package.loaded["telescope.finders"] = { new_table = function(opts) return opts end }
    package.loaded["telescope.config"] = { values = { generic_sorter = function() return function() end end } }
    package.loaded["telescope.actions"] = {
      close = function() end,
      select_default = { replace = function() end },
    }
    package.loaded["telescope.actions.state"] = {
      get_current_picker = function()
        return { get_multi_selection = function() return {} end }
      end,
      get_selected_entry = function() return nil end,
    }
    package.loaded["telescope.pickers"] = {
      new = function(_, opts)
        opts.attach_mappings(1, function(mode, lhs, _rhs)
          mapped[mode .. lhs] = true
        end)
        return { find = function() end }
      end,
    }

    local ok, err = pcall(function()
      history.pick({ data_dir = vim.fn.tempname(), adapters = {} })
    end)

    package.loaded["telescope.pickers"] = old_modules.pickers
    package.loaded["telescope.finders"] = old_modules.finders
    package.loaded["telescope.config"] = old_modules.config
    package.loaded["telescope.actions"] = old_modules.actions
    package.loaded["telescope.actions.state"] = old_modules.action_state

    assert.is_true(ok, err)
    assert.is_true(mapped["nd"])
    assert.is_true(mapped["id"])
  end)

  it("deletes the selected active session from the picker", function()
    local old_modules = {
      pickers = package.loaded["telescope.pickers"],
      finders = package.loaded["telescope.finders"],
      config = package.loaded["telescope.config"],
      actions = package.loaded["telescope.actions"],
      action_state = package.loaded["telescope.actions.state"],
    }
    local old_schedule = vim.schedule
    local mapped = {}
    local closed = false
    local record = session._new_record("local", "Active API")
    record.messages = { { role = "user", content = "hello" } }
    record.bufnr = vim.api.nvim_create_buf(false, true)
    session._add(record)

    vim.schedule = function() end
    package.loaded["telescope.finders"] = { new_table = function(opts) return opts end }
    package.loaded["telescope.config"] = { values = { generic_sorter = function() return function() end end } }
    package.loaded["telescope.actions"] = {
      close = function() closed = true end,
      select_default = { replace = function() end },
    }
    package.loaded["telescope.actions.state"] = {
      get_current_picker = function()
        return { get_multi_selection = function() return {} end }
      end,
      get_selected_entry = function()
        return { value = { id = record.id, adapter = record.adapter, title = record.title, status = "active" } }
      end,
    }
    package.loaded["telescope.pickers"] = {
      new = function(_, opts)
        opts.attach_mappings(1, function(mode, lhs, rhs)
          mapped[mode .. lhs] = rhs
        end)
        return { find = function() end }
      end,
    }

    local ok, err = pcall(function()
      history.pick({ data_dir = vim.fn.tempname(), adapters = {} })
      mapped["nd"]()
    end)

    vim.schedule = old_schedule
    package.loaded["telescope.pickers"] = old_modules.pickers
    package.loaded["telescope.finders"] = old_modules.finders
    package.loaded["telescope.config"] = old_modules.config
    package.loaded["telescope.actions"] = old_modules.actions
    package.loaded["telescope.actions.state"] = old_modules.action_state

    assert.is_true(ok, err)
    assert.is_true(closed)
    assert.is_nil(session._get(record.id))
    assert.is_falsy(record.bufnr and vim.api.nvim_buf_is_valid(record.bufnr))
  end)
end)
