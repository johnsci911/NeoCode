local provider = require("neocode.providers.llama_server")

describe("llama-server provider", function()
  it("uses props runtime context before model training context", function()
    local metadata = provider.metadata_from_responses({
      model_alias = "runtime-model",
      default_generation_settings = { n_ctx = 24576 },
    }, {
      data = {
        {
          id = "fallback-model",
          meta = { n_ctx = 32768, n_ctx_train = 262144 },
        },
      },
    })

    assert.equals("runtime-model", metadata.model)
    assert.equals(24576, metadata.context_size)
    assert.equals(262144, metadata.training_context_size)
    assert.equals("llama-server", metadata.provider)
    assert.is_false(metadata.estimated_context_size)
  end)

  it("detects thinking support from llama-server chat template caps", function()
    local metadata = provider.metadata_from_responses({
      model_alias = "template-model",
      chat_template_caps = { supports_thinking = true },
    }, {
      data = {
        { id = "fallback-model" },
      },
    })

    assert.is_true(metadata.thinking_available)
  end)

  it("detects thinking support from llama-server chat template enable_thinking", function()
    local metadata = provider.metadata_from_responses({
      model_alias = "template-model",
      chat_template = "{% if enable_thinking is defined and enable_thinking %}<|think|>{% endif %}",
    }, {
      data = {
        { id = "fallback-model" },
      },
    })

    assert.is_true(metadata.thinking_available)
    assert.equals("chat_template enable_thinking", metadata.thinking_source)
  end)

  it("detects thinking support from live llama-server slot reasoning format", function()
    local metadata = provider.metadata_from_responses({
      model_alias = "slot-model",
    }, {
      data = {
        { id = "fallback-model" },
      },
    }, {
      slots = {
        { params = { reasoning_format = "deepseek", reasoning_in_content = false } },
      },
    })

    assert.is_true(metadata.thinking_available)
    assert.equals("slots reasoning_format=deepseek", metadata.thinking_source)
    assert.equals("deepseek", metadata.reasoning_format)
  end)

  it("does not infer thinking support from model names", function()
    local metadata = provider.metadata_from_responses({
      model_alias = "qwen3-thinking-looking-name",
    }, {
      data = {
        { id = "deepseek-r1-looking-name" },
      },
    })

    assert.is_false(metadata.thinking_available)
  end)

  it("preserves explicit OpenAI-compatible reasoning capabilities through llama-server metadata", function()
    local metadata = provider.metadata_from_responses(nil, {
      data = {
        { id = "routed-model", capabilities = { "completion", "reasoning" } },
      },
    })

    assert.is_true(metadata.thinking_available)
  end)

  it("builds llama-server probe URLs from a v1 base URL", function()
    local configured = provider.setup({ base_url = "http://127.0.0.1:8080/v1" })

    assert.equals("http://127.0.0.1:8080", configured.server_url)
    assert.equals("http://127.0.0.1:8080/props", configured:props_url())
    assert.equals("http://127.0.0.1:8080/v1/models", configured:models_url())
    assert.equals("http://127.0.0.1:8080/models", configured:native_models_url())
    assert.equals("http://127.0.0.1:8080/slots", configured:slots_url())
  end)

  it("probes props, v1 models, and slots metadata by default", function()
    local seen = {}
    local configured = provider.setup({
      base_url = "http://127.0.0.1:8080/v1",
      read_json = function(url)
        table.insert(seen, url)
        if url:match("/props$") then
          return { model_alias = "props-model", default_generation_settings = { n_ctx = 24576 } }
        end
        if url:match("/v1/models$") then
          return { data = { { id = "models-model", meta = { n_ctx_train = 262144 } } } }
        end
        if url:match("/slots$") then
          return { { params = { reasoning_format = "deepseek" } } }
        end
      end,
    })

    local metadata = configured:probe_metadata()

    assert.same({ "http://127.0.0.1:8080/props", "http://127.0.0.1:8080/v1/models", "http://127.0.0.1:8080/slots" }, seen)
    assert.equals("props-model", metadata.model)
    assert.equals(24576, metadata.context_size)
    assert.equals(262144, metadata.training_context_size)
    assert.is_true(metadata.thinking_available)
    assert.equals("deepseek", metadata.reasoning_format)
  end)
end)
