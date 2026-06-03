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

  it("builds llama-server probe URLs from a v1 base URL", function()
    local configured = provider.setup({ base_url = "http://127.0.0.1:8080/v1" })

    assert.equals("http://127.0.0.1:8080", configured.server_url)
    assert.equals("http://127.0.0.1:8080/props", configured:props_url())
    assert.equals("http://127.0.0.1:8080/v1/models", configured:models_url())
    assert.equals("http://127.0.0.1:8080/models", configured:native_models_url())
    assert.equals("http://127.0.0.1:8080/slots", configured:slots_url())
  end)

  it("probes props and v1 models metadata by default", function()
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
      end,
    })

    local metadata = configured:probe_metadata()

    assert.same({ "http://127.0.0.1:8080/props", "http://127.0.0.1:8080/v1/models" }, seen)
    assert.equals("props-model", metadata.model)
    assert.equals(24576, metadata.context_size)
    assert.equals(262144, metadata.training_context_size)
  end)
end)
