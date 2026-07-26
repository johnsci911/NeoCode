local llama = require("neocode.adapters.llama")

describe("llama adapter", function()
  before_each(function()
    llama.setup({})
  end)

  it("launches Continue CLI as a normal terminal adapter", function()
    assert.equals("llama", llama.name)
    assert.is_nil(llama.type)
    assert.is_false(llama.session_store)
    assert.is_function(llama.launch_cmd)
    assert.is_function(llama.resume_cmd)
    assert.is_function(llama.interrupt)
    assert.is_function(llama.attach_image)
  end)

  it("resumes through Continue CLI history instead of NeoCode history", function()
    local spec = llama.resume_cmd({ cwd = "/tmp/project" })

    assert.equals("cn", spec.cmd)
    assert.same({ "--resume" }, spec.args)
    assert.equals("/tmp/project", spec.cwd)
    assert.is_nil(spec.env)
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

  it("extracts model and runtime context from llama-server metadata", function()
    local metadata = llama._metadata_from_responses({
      model_alias = "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF",
      default_generation_settings = { n_ctx = 24576 },
    }, {
      data = {
        {
          id = "fallback-model",
          meta = { n_ctx = 1234, n_ctx_train = 262144 },
        },
      },
    })

    assert.equals("unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF", metadata.model)
    assert.equals(24576, metadata.context_length)
    assert.equals(262144, metadata.training_context_length)
  end)

  it("extracts model and runtime context from v1 models when props are unavailable", function()
    local metadata = llama._metadata_from_responses(nil, {
      data = {
        {
          id = "unsloth/gemma-4-26B-A4B-it-GGUF",
          meta = { n_ctx = 32768, n_ctx_train = 262144 },
        },
      },
    })

    assert.equals("unsloth/gemma-4-26B-A4B-it-GGUF", metadata.model)
    assert.equals(32768, metadata.context_length)
    assert.equals(262144, metadata.training_context_length)
  end)

  it("builds a Continue config from detected llama-server metadata", function()
    local yaml = llama._build_continue_config({
      model = "local-model",
      context_length = 24576,
    }, {
      name = "Generated Local Llama",
      api_base = "http://127.0.0.1:8080/v1",
      max_tokens = 3500,
    })

    assert.is_truthy(yaml:find("name: Generated Local Llama", 1, true))
    assert.is_truthy(yaml:find("model: local-model", 1, true))
    assert.is_truthy(yaml:find("apiBase: http://127.0.0.1:8080/v1", 1, true))
    assert.is_truthy(yaml:find("contextLength: 24576", 1, true))
    assert.is_truthy(yaml:find("maxTokens: 3500", 1, true))
  end)

  it("does not duplicate v1 when llama_server already points at the OpenAI API base", function()
    local yaml = llama._build_continue_config({
      model = "local-model",
      context_length = 32768,
    }, {
      llama_server = "http://127.0.0.1:8080/v1",
    })

    assert.is_truthy(yaml:find("apiBase: http://127.0.0.1:8080/v1", 1, true))
    assert.is_falsy(yaml:find("/v1/v1", 1, true))
  end)

  it("launches Continue with a generated config when dynamic setup succeeds", function()
    local tmp = vim.fn.tempname()
    llama.setup({
      dynamic_continue_config = {
        enabled = true,
        output = tmp,
        probe = function()
          return { model = "local-model", context_length = 24576 }
        end,
      },
    })

    local spec = llama.launch_cmd({ cwd = "/tmp/project" })

    assert.same({ "--config", tmp }, spec.args)
    assert.equals(1, vim.fn.filereadable(tmp))
    assert.is_truthy(table.concat(vim.fn.readfile(tmp), "\n"):find("contextLength: 24576", 1, true))
    vim.fn.delete(tmp)
  end)

  it("preserves extra Continue CLI args when injecting generated config", function()
    local tmp = vim.fn.tempname()
    llama.setup({
      args = { "--verbose", "--config", "/old/config.yaml", "--trace" },
      dynamic_continue_config = {
        enabled = true,
        output = tmp,
        probe = function()
          return { model = "local-model", context_length = 24576 }
        end,
      },
    })

    local spec = llama.launch_cmd({ cwd = "/tmp/project" })

    assert.same({ "--verbose", "--trace", "--config", tmp }, spec.args)
    vim.fn.delete(tmp)
  end)

  it("resumes Continue history with a generated config when dynamic setup succeeds", function()
    local tmp = vim.fn.tempname()
    llama.setup({
      args = { "--verbose", "--config", "/old/config.yaml" },
      dynamic_continue_config = {
        enabled = true,
        output = tmp,
        probe = function()
          return { model = "local-model", context_length = 24576 }
        end,
      },
    })

    local spec = llama.resume_cmd({ cwd = "/tmp/project" })

    assert.same({ "--verbose", "--resume", "--config", tmp }, spec.args)
    assert.equals(1, vim.fn.filereadable(tmp))
    vim.fn.delete(tmp)
  end)

  it("does not expose the previous NeoCode-owned OpenAI API customization surface", function()
    assert.is_nil(llama.stream)
    assert.is_nil(llama.stream_with_tools)
    assert.is_nil(llama._build_system_prompt)
    assert.is_nil(llama._parse_text_tool_calls)
  end)
end)
