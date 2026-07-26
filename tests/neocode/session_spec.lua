local session = require("neocode.session")

describe("session", function()
  before_each(function()
    session._reset()
  end)

  describe("_new_record", function()
    it("creates a record with correct fields", function()
      local s = session._new_record("opencode", "Test session")
      assert.is_not_nil(s.id)
      assert.equals("opencode", s.adapter)
      assert.equals("Test session", s.title)
      assert.is_number(s.created_at)
      assert.equals("active", s.status)
      assert.is_nil(s.bufnr)
      assert.is_nil(s.winid)
      assert.is_nil(s.job_id)
    end)

    it("generates a title when none is provided", function()
      local s = session._new_record("pi")
      assert.is_truthy(s.title:find("^Session "))
    end)
  end)

  describe("_add / _get / _remove", function()
    it("_add() makes session retrievable by id", function()
      local s = session._new_record("opencode", "My chat")
      session._add(s)
      assert.equals(s, session._get(s.id))
    end)

    it("_remove() deletes session from table", function()
      local s = session._new_record("pi", "Temp")
      session._add(s)
      session._remove(s.id)
      assert.is_nil(session._get(s.id))
    end)

    it("_remove() clears _current_id when the removed session is current", function()
      local s = session._new_record("opencode", "Current")
      session._add(s)
      session._current_id = s.id
      session._remove(s.id)
      assert.is_nil(session._current_id)
    end)
  end)

  describe("_all", function()
    it("returns all sessions sorted by created_at", function()
      local s1 = session._new_record("opencode", "A")
      s1.created_at = 100
      local s2 = session._new_record("pi", "B")
      s2.created_at = 200
      session._add(s1)
      session._add(s2)
      local all = session._all()
      assert.equals(2, #all)
      assert.equals("A", all[1].title)
      assert.equals("B", all[2].title)
    end)
  end)

  describe("_current", function()
    it("returns the current session", function()
      local s = session._new_record("opencode", "Current")
      session._add(s)
      session._current_id = s.id
      assert.equals(s, session._current())
    end)

    it("returns nil when no current session", function()
      assert.is_nil(session._current())
    end)
  end)

  describe("_rename_record", function()
    it("rejects empty titles", function()
      local record = session._new_record("opencode", "Original")
      assert.is_false(session._rename_record(record, ""))
      assert.is_false(session._rename_record(record, "   "))
    end)

    it("trims whitespace from new titles", function()
      local record = session._new_record("opencode", "Original")
      assert.is_true(session._rename_record(record, "  New Title  "))
      assert.equals("New Title", record.title)
    end)
  end)

  describe("_show_session_in_window", function()
    it("returns false when session has no valid buffer", function()
      assert.is_false(session._show_session_in_window({ bufnr = nil }, vim.api.nvim_get_current_win()))
    end)

    it("reclaims window from other sessions", function()
      local win = vim.api.nvim_get_current_win()
      local first = session._new_record("opencode", "First")
      local second = session._new_record("pi", "Second")
      first.bufnr = vim.api.nvim_create_buf(false, true)
      second.bufnr = vim.api.nvim_create_buf(false, true)
      session._add(first)
      session._add(second)

      session._show_session_in_window(first, win)
      assert.equals(first, session._current())

      session._show_session_in_window(second, win)
      assert.equals(second, session._current())
      assert.is_nil(first.winid)

      if vim.api.nvim_buf_is_valid(first.bufnr) then
        vim.api.nvim_buf_delete(first.bufnr, { force = true })
      end
      if vim.api.nvim_buf_is_valid(second.bufnr) then
        vim.api.nvim_buf_delete(second.bufnr, { force = true })
      end
    end)
  end)

  describe("create (CLI terminal flow)", function()
    it("reuses the current NeoCode window when creating another CLI session", function()
      local initial_win = vim.api.nvim_get_current_win()
      local initial_windows = #vim.api.nvim_list_wins()
      local old_termopen = vim.fn.termopen
      vim.fn.termopen = function()
        return 9001
      end
      local adapter = {
        name = "mockcli",
        launch_cmd = function()
          return { cmd = "mockcli", args = {} }
        end,
      }

      local ok, err = pcall(function()
        session.create(adapter, "First CLI", { winbar = "" })
        local after_first = #vim.api.nvim_list_wins()
        session.create(adapter, "Second CLI", { winbar = "" })
        local after_second = #vim.api.nvim_list_wins()
        local first, second
        for _, s in ipairs(session._all()) do
          if s.title == "First CLI" then first = s end
          if s.title == "Second CLI" then second = s end
        end

        assert.equals(initial_windows + 1, after_first)
        assert.equals(after_first, after_second)
        assert.is_nil(first.winid)
        assert.is_number(second.winid)
        assert.is_true(vim.api.nvim_win_is_valid(second.winid))
      end)

      vim.fn.termopen = old_termopen
      for _, s in ipairs(session._all()) do
        if s.bufnr and vim.api.nvim_buf_is_valid(s.bufnr) then
          pcall(vim.api.nvim_buf_delete, s.bufnr, { force = true })
        end
      end
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if win ~= initial_win and vim.api.nvim_win_is_valid(win) then
          pcall(vim.api.nvim_win_close, win, true)
        end
      end
      if vim.api.nvim_win_is_valid(initial_win) then
        vim.api.nvim_set_current_win(initial_win)
      end
      assert.is_true(ok, err)
    end)

    it("spawns a new CLI session in the existing NeoCode window after launcher buffer focus", function()
      local initial_win = vim.api.nvim_get_current_win()
      local initial_windows = #vim.api.nvim_list_wins()
      local old_termopen = vim.fn.termopen
      vim.fn.termopen = function()
        return 9002
      end
      local old_record = session._new_record("mockcli", "Old CLI")
      old_record.bufnr = vim.api.nvim_create_buf(false, true)
      old_record.winid = initial_win
      session._add(old_record)
      session._show_session_in_window(old_record, initial_win)
      session._mark_transient_session_open(initial_win)
      local launcher_buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_win_set_buf(initial_win, launcher_buf)
      local adapter = {
        name = "mockcli",
        launch_cmd = function()
          return { cmd = "mockcli", args = {} }
        end,
      }

      local ok, err = pcall(function()
        session.create(adapter, "New CLI", { winbar = "" })
        local new_record = session._current()

        assert.equals(initial_windows, #vim.api.nvim_list_wins())
        assert.equals(initial_win, new_record.winid)
        assert.equals(new_record.bufnr, vim.api.nvim_win_get_buf(initial_win))
        assert.is_nil(old_record.winid)
      end)

      vim.fn.termopen = old_termopen
      for _, s in ipairs(session._all()) do
        if s.bufnr and vim.api.nvim_buf_is_valid(s.bufnr) then
          pcall(vim.api.nvim_buf_delete, s.bufnr, { force = true })
        end
      end
      if vim.api.nvim_buf_is_valid(launcher_buf) then
        pcall(vim.api.nvim_buf_delete, launcher_buf, { force = true })
      end
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if win ~= initial_win and vim.api.nvim_win_is_valid(win) then
          pcall(vim.api.nvim_win_close, win, true)
        end
      end
      if vim.api.nvim_win_is_valid(initial_win) then
        vim.api.nvim_set_current_win(initial_win)
      end
      assert.is_true(ok, err)
    end)
  end)

  describe("delete_active", function()
    it("removes a session and switches to the remaining one", function()
      local win = vim.api.nvim_get_current_win()
      local first = session._new_record("opencode", "First")
      local second = session._new_record("opencode", "Second")
      first.bufnr = vim.api.nvim_create_buf(false, true)
      second.bufnr = vim.api.nvim_create_buf(false, true)
      session._add(first)
      session._add(second)
      session._show_session_in_window(first, win)

      local ok, err = pcall(function()
        assert.is_true(session.delete_active(first.id, { data_dir = vim.fn.tempname() }))
      end)

      if second.bufnr and vim.api.nvim_buf_is_valid(second.bufnr) then
        vim.api.nvim_buf_delete(second.bufnr, { force = true })
      end
      assert.is_true(ok, err)
      assert.equals(second, session._current())
    end)
  end)

  describe("rename_on_disk", function()
    it("updates the title in sessions.json", function()
      local tmp = vim.fn.tempname()
      vim.fn.mkdir(tmp, "p")
      local all = {
        { id = "sess-1", adapter = "opencode", title = "Old Title", created_at = 100, cwd = "/tmp" },
        { id = "sess-2", adapter = "pi", title = "Keep", created_at = 200, cwd = "/tmp" },
      }
      local ok, encoded = pcall(vim.fn.json_encode, all)
      local f = io.open(tmp .. "/sessions.json", "w")
      f:write(encoded)
      f:close()

      session.rename_on_disk("sess-1", "New Title", { data_dir = tmp })

      local f2 = io.open(tmp .. "/sessions.json", "r")
      local raw = f2:read("*a")
      f2:close()
      local decoded = vim.fn.json_decode(raw)
      assert.equals("New Title", decoded[1].title)
      assert.equals("Keep", decoded[2].title)
      vim.fn.delete(tmp, "rf")
    end)
  end)

  describe("load_all_from_disk", function()
    it("returns sessions from sessions.json", function()
      local tmp = vim.fn.tempname()
      vim.fn.mkdir(tmp, "p")
      local all = {
        { id = "sess-1", adapter = "opencode", title = "Disk Session", created_at = 100, cwd = "/tmp" },
      }
      local ok, encoded = pcall(vim.fn.json_encode, all)
      local f = io.open(tmp .. "/sessions.json", "w")
      f:write(encoded)
      f:close()

      local loaded = session.load_all_from_disk({ data_dir = tmp })
      assert.equals(1, #loaded)
      assert.equals("Disk Session", loaded[1].title)
      vim.fn.delete(tmp, "rf")
    end)

    it("returns empty table for missing file", function()
      local tmp = vim.fn.tempname()
      vim.fn.mkdir(tmp, "p")
      local loaded = session.load_all_from_disk({ data_dir = tmp })
      assert.equals(0, #loaded)
      vim.fn.delete(tmp, "rf")
    end)
  end)
end)
