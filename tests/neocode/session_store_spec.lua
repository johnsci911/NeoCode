local session_store = require("neocode.session_store")

describe("session_store", function()
  local tmp_dir
  local store

  before_each(function()
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
    store = session_store.new({ data_dir = tmp_dir, cwd = "/Users/example/project" })
  end)

  after_each(function()
    vim.fn.delete(tmp_dir, "rf")
  end)

  it("stores session data under a project-scoped global directory", function()
    local meta = { id = "sess-1", adapter = "llama", title = "Layered", created_at = 123 }

    store.save_meta(meta)

    local path = store.session_dir("sess-1") .. "/meta.json"
    assert.equals(1, vim.fn.filereadable(path))
    assert.is_truthy(path:find(tmp_dir .. "/projects/", 1, true))
    assert.is_truthy(path:find("/sessions/sess-1/meta.json", 1, true))
  end)

  it("keeps prompt-ready messages separate from append-only transcript events", function()
    local messages = {
      { role = "user", content = "hello" },
      { role = "assistant", content = "hi" },
    }

    store.save_messages("sess-1", messages)
    store.append_transcript("sess-1", { role = "user", content = "hello" })
    store.append_transcript("sess-1", { role = "assistant", content = "hi" })

    assert.are.same(messages, store.load_messages("sess-1"))

    local transcript_path = store.session_dir("sess-1") .. "/transcript.jsonl"
    local lines = vim.fn.readfile(transcript_path)
    assert.equals(2, #lines)
    local first = vim.fn.json_decode(lines[1])
    local second = vim.fn.json_decode(lines[2])
    assert.equals("user", first.role)
    assert.equals("assistant", second.role)
  end)

  it("writes summaries without deleting the raw transcript", function()
    store.append_transcript("sess-1", { role = "user", content = "important raw detail" })

    store.save_summary("sess-1", "Compacted summary")

    assert.equals("Compacted summary", store.load_summary("sess-1"))
    local transcript = table.concat(vim.fn.readfile(store.session_dir("sess-1") .. "/transcript.jsonl"), "\n")
    assert.is_truthy(transcript:find("important raw detail", 1, true))
  end)

  it("rejects unsafe session ids before building paths", function()
    assert.is_false(session_store.is_valid_session_id("../escape"))
    assert.is_false(session_store.is_valid_session_id("nested/session"))
    assert.is_false(session_store.is_valid_session_id(""))
    assert.is_true(session_store.is_valid_session_id("neocode_123_1"))

    local ok = pcall(function()
      store.save_messages("../escape", {})
    end)
    assert.is_false(ok)
  end)

  it("deletes all files for a stored session", function()
    store.save_messages("sess-1", { { role = "user", content = "hello" } })
    store.append_transcript("sess-1", { role = "assistant", content = "hi" })

    store.delete_session("sess-1")

    assert.equals(0, vim.fn.isdirectory(store.session_dir("sess-1")))
  end)

  it("creates private session directories and files", function()
    store.save_messages("sess-1", { { role = "user", content = "secret" } })

    assert.equals("rwx------", vim.fn.getfperm(store.session_dir("sess-1")))
    assert.equals("rw-------", vim.fn.getfperm(store.session_dir("sess-1") .. "/messages.json"))
  end)
end)
