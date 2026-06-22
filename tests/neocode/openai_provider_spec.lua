local provider = require("neocode.providers.openai")

describe("openai provider", function()
  it("uses OpenAI endpoints and bearer auth", function()
    local configured = provider.setup({ api_key = "test-key" })

    assert.equals("https://api.openai.com/v1", configured.base_url)
    assert.equals("https://api.openai.com/v1/models", configured:models_url())
    assert.equals("https://api.openai.com/v1/chat/completions", configured:chat_completions_url())
    assert.same({ "-H", "Authorization: Bearer test-key" }, configured:curl_auth_args())
  end)

  it("discovers an available chat model from OpenAI models response", function()
    local seen_url = nil
    local seen_opts = nil
    local configured = provider.setup({
      api_key = "test-key",
      read_json = function(url, opts)
        seen_url = url
        seen_opts = opts
        return {
          data = {
            { id = "whisper-1" },
            { id = "gpt-4o-mini" },
            { id = "gpt-4o" },
          },
        }
      end,
    })

    local metadata = configured:probe_metadata()

    assert.equals("https://api.openai.com/v1/models", seen_url)
    assert.equals("Bearer test-key", seen_opts.headers.Authorization)
    assert.equals("openai", metadata.provider)
    assert.equals("gpt-4o-mini", metadata.model)
    assert.is_true(metadata.estimated_context_size)
  end)
end)
