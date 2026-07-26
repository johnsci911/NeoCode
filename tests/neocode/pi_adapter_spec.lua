local pi = require("neocode.adapters.pi")

describe("pi adapter", function()
  it("has correct adapter metadata", function()
    assert.equals("pi", pi.name)
    assert.is_false(pi.session_store)
    assert.is_function(pi.launch_cmd)
    assert.is_function(pi.resume_cmd)
    assert.is_function(pi.interrupt)
    assert.is_function(pi.attach_image)
  end)

  it("launches Pi CLI with default args", function()
    local spec = pi.launch_cmd({ cwd = "/tmp/project" })

    assert.equals("pi", spec.cmd)
    assert.same({}, spec.args)
    assert.equals("/tmp/project", spec.cwd)
    assert.is_nil(spec.env)
  end)

  it("passes name to Pi CLI", function()
    local spec = pi.launch_cmd({ cwd = "/tmp/project", name = "My Session" })

    assert.same({ "--name", "My Session" }, spec.args)
  end)

  it("passes provider to Pi CLI", function()
    local spec = pi.launch_cmd({ cwd = "/tmp/project", provider = "llama.cpp" })

    assert.same({ "--provider", "llama.cpp" }, spec.args)
  end)

  it("passes model to Pi CLI", function()
    local spec = pi.launch_cmd({ cwd = "/tmp/project", model = "qwen2.5-coder" })

    assert.same({ "--model", "qwen2.5-coder" }, spec.args)
  end)

  it("combines all optional args", function()
    local spec = pi.launch_cmd({
      cwd = "/tmp/project",
      name = "Test",
      provider = "ollama",
      model = "llama3",
    })

    assert.same({ "--name", "Test", "--provider", "ollama", "--model", "llama3" }, spec.args)
  end)

  it("opens Pi with --resume when resuming", function()
    local spec = pi.resume_cmd({ cwd = "/tmp/project" })

    assert.equals("pi", spec.cmd)
    assert.same({ "--resume" }, spec.args)
    assert.equals("/tmp/project", spec.cwd)
  end)

  it("sends interrupt signal to the session", function()
    local sent = false
    local original = vim.fn.chansend
    vim.fn.chansend = function(job_id, data)
      assert.equals(42, job_id)
      assert.equals("\x03", data)
      sent = true
    end

    pi.interrupt({ job_id = 42 })

    vim.fn.chansend = original
    assert.is_true(sent)
  end)

  it("does nothing when session is nil", function()
    local called = false
    local original = vim.fn.chansend
    vim.fn.chansend = function() called = true end

    pi.interrupt(nil)

    vim.fn.chansend = original
    assert.is_false(called)
  end)

  it("sends image path to the terminal session", function()
    local sent = {}
    local original = vim.fn.chansend
    vim.fn.chansend = function(job_id, data)
      table.insert(sent, { job_id = job_id, data = data })
    end

    pi.attach_image({ job_id = 42 }, "/tmp/screenshot.png")

    vim.fn.chansend = original

    assert.same({ { job_id = 42, data = "/tmp/screenshot.png\n" } }, sent)
  end)

  it("does nothing when path is empty", function()
    local sent = false
    local original = vim.fn.chansend
    vim.fn.chansend = function() sent = true end

    pi.attach_image({ job_id = 42 }, "")

    vim.fn.chansend = original
    assert.is_false(sent)
  end)
end)
