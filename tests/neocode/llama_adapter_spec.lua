local llama = require("neocode.adapters.llama")

describe("llama adapter", function()
  before_each(function()
    llama.setup({})
  end)

  it("launches Continue CLI as a normal terminal adapter", function()
    assert.equals("llama", llama.name)
    assert.is_nil(llama.type)
    assert.is_true(llama.session_store)
    assert.is_function(llama.launch_cmd)
    assert.is_function(llama.interrupt)
    assert.is_function(llama.attach_image)
  end)

  it("uses cn by default and lets Continue own the local model configuration", function()
    local spec = llama.launch_cmd({ cwd = "/tmp/project", name = "Llama Local" })

    assert.equals("cn", spec.cmd)
    assert.same({}, spec.args)
    assert.equals("/tmp/project", spec.cwd)
    assert.is_nil(spec.env)
  end)

  it("allows users to point at a different Continue CLI command without model flags", function()
    llama.setup({ command = "continue", args = { "--config", "/tmp/continue.yaml" } })

    local spec = llama.launch_cmd({ cwd = "/tmp/project" })

    assert.equals("continue", spec.cmd)
    assert.same({ "--config", "/tmp/continue.yaml" }, spec.args)
  end)

  it("does not expose the previous NeoCode-owned OpenAI API customization surface", function()
    assert.is_nil(llama.stream)
    assert.is_nil(llama.stream_with_tools)
    assert.is_nil(llama._build_system_prompt)
    assert.is_nil(llama._parse_text_tool_calls)
  end)
end)
