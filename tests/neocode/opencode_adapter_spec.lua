local opencode = require("neocode.adapters.opencode")

describe("opencode adapter", function()
  it("launches OpenCode as a normal terminal adapter", function()
    local spec = opencode.launch_cmd({ cwd = "/tmp/project" })

    assert.equals("opencode", opencode.name)
    assert.is_nil(opencode.type)
    assert.is_false(opencode.session_store)
    assert.equals("opencode", spec.cmd)
    assert.same({}, spec.args)
    assert.equals("/tmp/project", spec.cwd)
    assert.is_nil(spec.env)
  end)

  it("opens OpenCode's latest session when resuming", function()
    local spec = opencode.resume_cmd({ cwd = "/tmp/project" })

    assert.equals("opencode", spec.cmd)
    assert.same({ "--continue" }, spec.args)
    assert.equals("/tmp/project", spec.cwd)
  end)

  it("sends attached paths to the terminal session", function()
    local sent = {}
    local original = vim.fn.chansend
    vim.fn.chansend = function(job_id, data)
      table.insert(sent, { job_id = job_id, data = data })
    end

    local ok, err = pcall(function()
      opencode.attach_image({ job_id = 42 }, "/tmp/screenshot.png")
    end)
    vim.fn.chansend = original

    assert.is_true(ok, err)
    assert.same({ { job_id = 42, data = "/tmp/screenshot.png\n" } }, sent)
  end)
end)
