local provider = require("neocode.providers.openai_compatible")

describe("openai compatible provider", function()
  it("normalizes endpoint URLs without duplicating v1", function()
    local configured = provider.setup({ base_url = "http://127.0.0.1:8080/v1/" })

    assert.equals("http://127.0.0.1:8080/v1", configured.base_url)
    assert.equals("http://127.0.0.1:8080/v1/chat/completions", configured:chat_completions_url())
    assert.equals("http://127.0.0.1:8080/v1/models", configured:models_url())
  end)

  it("extracts model and context metadata from OpenAI-style models response", function()
    local metadata = provider.metadata_from_models({
      data = {
        {
          id = "unsloth/gemma-4-26B-A4B-it-GGUF",
          meta = { n_ctx = 32768, n_ctx_train = 262144 },
        },
      },
    })

    assert.equals("unsloth/gemma-4-26B-A4B-it-GGUF", metadata.model)
    assert.equals(32768, metadata.context_size)
    assert.equals(262144, metadata.training_context_size)
    assert.is_false(metadata.estimated_context_size)
  end)

  it("marks context as estimated when model metadata does not expose a context window", function()
    local metadata = provider.metadata_from_models({
      data = {
        { id = "local-model" },
      },
    }, { fallback_context_size = 8192 })

    assert.equals("local-model", metadata.model)
    assert.equals(8192, metadata.context_size)
    assert.is_true(metadata.estimated_context_size)
  end)

  it("detects thinking support from explicit model capabilities", function()
    local metadata = provider.metadata_from_models({
      data = {
        { id = "explicit-reasoning-model", capabilities = { "completion", "reasoning" } },
      },
    })

    assert.is_true(metadata.thinking_available)
  end)

  it("detects thinking support from explicit model metadata flags", function()
    local metadata = provider.metadata_from_models({
      data = {
        { id = "explicit-metadata-model", meta = { supports_thinking = true } },
      },
    })

    assert.is_true(metadata.thinking_available)
  end)

  it("does not infer thinking support from model names", function()
    local metadata = provider.metadata_from_models({
      data = {
        { id = "deepseek-r1-thinking-looking-name" },
      },
    })

    assert.is_false(metadata.thinking_available)
  end)

  it("probes model metadata from the OpenAI models endpoint", function()
    local seen_url = nil
    local configured = provider.setup({
      base_url = "http://127.0.0.1:1234/v1",
      read_json = function(url)
        seen_url = url
        return {
          data = {
            { id = "detected-openai-model", meta = { n_ctx = 16384 } },
          },
        }
      end,
    })

    local metadata = configured:probe_metadata()

    assert.equals("http://127.0.0.1:1234/v1/models", seen_url)
    assert.equals("detected-openai-model", metadata.model)
    assert.equals(16384, metadata.context_size)
    assert.is_false(metadata.estimated_context_size)
  end)
end)
