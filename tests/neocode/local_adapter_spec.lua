local neocode = require("neocode")
local local_adapter = require("neocode.adapters.local")

local function no_metadata_read()
  return nil
end

describe("local adapter", function()
  before_each(function()
    local_adapter.setup({ read_json = no_metadata_read })
  end)

  it("exposes NeoCode Local as an API-backed session adapter", function()
    assert.equals("local", local_adapter.name)
    assert.equals("api", local_adapter.type)
    assert.is_true(local_adapter.session_store)
    assert.is_function(local_adapter.setup)
    assert.is_function(local_adapter.stream)
    assert.is_function(local_adapter.stream_with_tools)
    assert.is_function(local_adapter._build_user_message)
  end)

  it("is accepted by neocode setup validation", function()
    assert.has_no_error(function()
      neocode.setup({
        default_adapter = "local",
        adapters = { ["local"] = local_adapter },
      })
    end)
  end)

  it("defaults to OpenAI-compatible local endpoint settings", function()
    local_adapter.setup({ read_json = no_metadata_read })

    assert.equals("http://127.0.0.1:8080/v1", local_adapter.config.base_url)
    assert.equals("openai_compatible", local_adapter.config.provider)
    assert.equals(32768, local_adapter.config.context_size)
  end)

  it("auto-detects llama-server thinking metadata from the default local endpoint", function()
    local_adapter.setup({
      base_url = "http://127.0.0.1:8080/v1",
      read_json = function(url)
        if url:match("/v1/models$") then
          return {
            data = {
              {
                id = "MoonRide/gemma-4-12B-it-heretic-custom-GGUF",
                capabilities = { "completion", "multimodal" },
              },
            },
          }
        end
        if url:match("/props$") then
          return {
            model_alias = "MoonRide/gemma-4-12B-it-heretic-custom-GGUF",
            chat_template = "{% if enable_thinking is defined and enable_thinking %}<|think|>{% endif %}",
            default_generation_settings = { n_ctx = 24576 },
          }
        end
        if url:match("/slots$") then
          return {
            { params = { reasoning_format = "deepseek", reasoning_in_content = false } },
          }
        end
      end,
    })

    assert.equals("llama_server", local_adapter.config.provider)
    assert.is_true(local_adapter.thinking_available())
    assert.equals("deepseek", local_adapter.config.reasoning_format)

    local ok, message = local_adapter.set_thinking("low")
    assert.is_true(ok)
    assert.is_truthy(message:find("slots reasoning_format=deepseek", 1, true))
  end)

  it("auto-detects llama-server runtime context even without thinking metadata", function()
    local props_context = 24576
    local_adapter.setup({
      base_url = "http://127.0.0.1:8080/v1",
      read_json = function(url)
        if url:match("/v1/models$") then
          return { data = { { id = "plain-local-model", meta = { n_ctx_train = 262144 } } } }
        end
        if url:match("/props$") then
          return {
            model_alias = "plain-local-model",
            default_generation_settings = { n_ctx = props_context },
          }
        end
      end,
    })

    assert.equals("llama_server", local_adapter.config.provider)
    assert.equals(24576, local_adapter.config.context_size)

    props_context = 64000
    assert.is_true(local_adapter.refresh_metadata())
    assert.equals(64000, local_adapter.config.context_size)
  end)

  it("respects an explicit OpenAI-compatible provider even when llama-server metadata exists", function()
    local_adapter.setup({
      provider = "openai_compatible",
      base_url = "http://127.0.0.1:8080/v1",
      read_json = function(url)
        if url:match("/v1/models$") then
          return { data = { { id = "generic-local-model" } } }
        end
        if url:match("/props$") then
          return { chat_template = "{% if enable_thinking %}<think>{% endif %}" }
        end
        if url:match("/slots$") then
          return { { params = { reasoning_format = "deepseek" } } }
        end
      end,
    })

    assert.equals("openai_compatible", local_adapter.config.provider)
    assert.is_false(local_adapter.thinking_available())
  end)

  it("can prefer llama-server provider enhancements", function()
    local_adapter.setup({
      provider = "llama_server",
      base_url = "http://127.0.0.1:8080/v1",
      model = "local-model",
      read_json = no_metadata_read,
    })

    assert.equals("llama_server", local_adapter.config.provider)
    assert.equals("local-model", local_adapter.config.model)
    assert.equals("http://127.0.0.1:8080/v1", local_adapter.base_url)
    assert.equals("local-model", local_adapter.model)
  end)

  it("uses probed provider metadata to populate model and context for compaction", function()
    local_adapter.setup({
      provider_probe = function()
        return {
          model = "detected-model",
          context_size = 24576,
          estimated_context_size = false,
        }
      end,
    })

    assert.equals("detected-model", local_adapter.config.model)
    assert.equals("detected-model", local_adapter.model)
    assert.equals(24576, local_adapter.config.context_size)
  end)

  it("uses provider metadata, not model names, to determine thinking availability", function()
    local_adapter.setup({
      provider = "llama_server",
      provider_probe = function()
        return {
          model = "qwen3-thinking-looking-name",
          thinking_available = false,
        }
      end,
    })

    assert.is_false(local_adapter.thinking_available())
    local ok, message = local_adapter.set_thinking("medium")
    assert.is_false(ok)
    assert.equals("Thinking mode not available", message)
  end)

  it("allows thinking presets only when provider metadata reports support", function()
    local_adapter.setup({
      provider = "llama_server",
      provider_probe = function()
        return {
          model = "metadata-enabled-model",
          thinking_available = true,
          thinking_source = "slots reasoning_format=deepseek",
          reasoning_format = "deepseek",
        }
      end,
    })

    local ok, message = local_adapter.set_thinking("medium")
    assert.is_true(ok)
    assert.equals("thinking mode: medium (enabled for next request; confirmed by slots reasoning_format=deepseek)", message)

    local payload = local_adapter._request_payload({
      { role = "user", content = "think" },
    })

    assert.is_true(payload.enable_thinking)
    assert.equals("deepseek", payload.reasoning_format)
    assert.is_true(payload.chat_template_kwargs.enable_thinking)
    assert.equals("medium", payload.chat_template_kwargs.reasoning_effort)
    assert.equals(2048, payload.thinking_budget_tokens)
  end)

  it("omits thinking fields in payloads when metadata does not report support", function()
    local_adapter.setup({
      model = "deepseek-r1-looking-name",
      thinking = "high",
      thinking_available = false,
    })

    local payload = local_adapter._request_payload({
      { role = "user", content = "think" },
    })

    assert.is_nil(payload.enable_thinking)
    assert.is_nil(payload.chat_template_kwargs)
    assert.is_nil(payload.thinking_budget_tokens)
  end)

  it("sends explicit thinking-off fields when metadata reports support and mode is off", function()
    local_adapter.setup({
      model = "metadata-enabled-model",
      thinking = "off",
      thinking_available = true,
    })

    local payload = local_adapter._request_payload({
      { role = "user", content = "hello" },
    })

    assert.is_false(payload.enable_thinking)
    assert.is_false(payload.chat_template_kwargs.enable_thinking)
    assert.equals(0, payload.thinking_budget_tokens)
  end)

  it("builds text and image user messages for the session flow", function()
    local text_only = local_adapter._build_user_message("hello", nil)
    local with_image = local_adapter._build_user_message("look", "abc123")

    assert.same({ role = "user", content = "hello" }, text_only)
    assert.equals("user", with_image.role)
    assert.is_table(with_image.content)
    assert.equals("text", with_image.content[1].type)
    assert.equals("look", with_image.content[1].text)
    assert.equals("image_url", with_image.content[2].type)
    assert.equals("data:image/png;base64,abc123", with_image.content[2].image_url.url)
  end)

  it("builds text and multiple image user messages for pasted image placeholders", function()
    local with_images = local_adapter._build_user_message("compare <image0> and <image1>", { "abc123", "def456" })

    assert.equals("user", with_images.role)
    assert.is_table(with_images.content)
    assert.equals("text", with_images.content[1].type)
    assert.equals("compare <image0> and <image1>", with_images.content[1].text)
    assert.equals("image_url", with_images.content[2].type)
    assert.equals("data:image/png;base64,abc123", with_images.content[2].image_url.url)
    assert.equals("image_url", with_images.content[3].type)
    assert.equals("data:image/png;base64,def456", with_images.content[3].image_url.url)
  end)

  it("builds OpenAI chat completion payloads with tools when provided", function()
    local_adapter.setup({ model = "local-model", temperature = 0.1, max_tokens = 123, read_json = no_metadata_read })

    local payload = local_adapter._request_payload({
      { role = "user", content = "read README" },
    }, {
      tools = {
        { type = "function", ["function"] = { name = "neocode__read_file" } },
      },
    })

    assert.equals("local-model", payload.model)
    assert.is_false(payload.stream)
    assert.equals(0.1, payload.temperature)
    assert.equals(123, payload.max_tokens)
    assert.is_nil(payload.enable_thinking)
    assert.is_nil(payload.chat_template_kwargs)
    assert.equals("read README", payload.messages[1].content)
    assert.equals("neocode__read_file", payload.tools[1]["function"].name)
  end)

  it("does not pass large image payloads through curl argv", function()
    local_adapter.setup({ model = "local-model", read_json = no_metadata_read })
    local original_jobstart = vim.fn.jobstart
    local captured_argv = nil
    vim.fn.jobstart = function(argv, opts)
      captured_argv = argv
      if opts and opts.on_stdout then opts.on_stdout(77, { '{"choices":[{"message":{"content":"ok"}}]}' }) end
      if opts and opts.on_exit then opts.on_exit(77, 0) end
      return 77
    end

    local large_image = string.rep("a", 200000)
    local ok, err = pcall(function()
      local_adapter.stream({
        local_adapter._build_user_message("look <image0>", { large_image }),
      }, nil, function() end)
    end)
    vim.fn.jobstart = original_jobstart

    assert.is_true(ok, err)
    assert.is_table(captured_argv)
    for _, arg in ipairs(captured_argv) do
      assert.is_true(#tostring(arg) < 10000)
    end
  end)

  it("sanitizes corrupted assistant history before building request payloads", function()
    local_adapter.setup({ model = "local-model", read_json = no_metadata_read })

    local payload = local_adapter._request_payload({
      { role = "user", content = "hello" },
      {
        role = "assistant",
        content = "<|channel>thought\n<channel|>�\nthought-thought-thought-thought-thought-thought-thought-thought",
      },
      {
        role = "assistant",
        content = "<|channel>thought garbage <|start_header_id|>assistant<|end_header_id|>Here is the useful answer.",
      },
      { role = "user", content = "continue" },
    })

    assert.equals(3, #payload.messages)
    assert.equals("user", payload.messages[1].role)
    assert.equals("assistant", payload.messages[2].role)
    assert.equals("Here is the useful answer.", payload.messages[2].content)
    assert.equals("user", payload.messages[3].role)
  end)

  it("extracts response text and context stats from OpenAI responses", function()
    local_adapter.setup({ provider = "llama_server", model = "local-model", context_size = 24576, read_json = no_metadata_read })

    local text, stats = local_adapter._complete_from_result({
      choices = {
        { message = { content = "done" } },
      },
      usage = { prompt_tokens = 100, completion_tokens = 25, total_tokens = 125 },
    })

    assert.equals("done", text)
    assert.equals("llama_server", stats.provider)
    assert.equals("local-model", stats.model)
    assert.equals(24576, stats.context_size)
    assert.equals(100, stats.usage.prompt_tokens)
    assert.equals(125, stats.usage.total_tokens)
  end)

  it("confirms thinking only when llama.cpp returns reasoning content", function()
    local_adapter.setup({ provider = "llama_server", model = "local-model", thinking = "low", thinking_available = true, read_json = no_metadata_read })

    local text, stats = local_adapter._complete_from_result({
      choices = {
        { message = { content = "done", reasoning_content = "hidden reasoning" } },
      },
      usage = { prompt_tokens = 10, completion_tokens = 5, total_tokens = 15 },
    })

    assert.equals("done", text)
    assert.is_true(stats.thinking_confirmed)
    assert.equals("low", stats.thinking_mode)
  end)

  it("strips leaked local thinking and chat-template preambles from responses", function()
    local_adapter.setup({ provider = "llama_server", model = "local-model", read_json = no_metadata_read })

    local text = local_adapter._complete_from_result({
      choices = {
        {
          message = {
            content = "<think>planning hidden answer</think>\n--? pleee- de- de- de- It looks like final answer text.",
          },
        },
      },
    })

    assert.equals("It looks like final answer text.", text)
  end)

  it("strips reserved channel-thought artifacts from responses", function()
    local_adapter.setup({ provider = "llama_server", model = "local-model", read_json = no_metadata_read })

    local text = local_adapter._complete_from_result({
      choices = {
        {
          message = {
            content = "<|channel>thought\n<channel|>�\nthought-thought-thought-thought-thought-thought-thought-thought\nHere is the final response.",
          },
        },
      },
    })

    assert.equals("Here is the final response.", text)
  end)

  it("normalizes model-escaped markdown fences in responses", function()
    local_adapter.setup({ provider = "llama_server", model = "local-model", read_json = no_metadata_read })

    local text = local_adapter._complete_from_result({
      choices = {
        {
          message = {
            content = "Tip:\n\\```python\nprint('hello')\n\\```",
          },
        },
      },
    })

    assert.equals("Tip:\n```python\nprint('hello')\n```", text)
  end)

  it("surfaces API errors instead of returning blank completions", function()
    local text, stats = local_adapter._complete_from_result({
      error = { message = "model not found" },
    })

    assert.equals("Local model request failed: model not found", text)
    assert.is_true(stats.error)
  end)

  it("extracts context usage from local context overflow errors", function()
    local_adapter.setup({ provider = "llama_server", model = "local-model", context_size = 64000, read_json = no_metadata_read })

    local _, stats = local_adapter._complete_from_result({
      error = { message = "request (33170 tokens) exceeds the available context size (32768 tokens), try increasing it" },
    })

    assert.is_true(stats.error)
    assert.equals(33170, stats.usage.prompt_tokens)
    assert.equals(0, stats.usage.completion_tokens)
    assert.equals(33170, stats.usage.total_tokens)
    assert.equals(32768, stats.context_size)
  end)

  it("executes tool calls and continues with tool results", function()
    local_adapter.setup({ model = "local-model", read_json = no_metadata_read })
    local requests = {}
    local_adapter._transport = function(messages, extra, callback)
      table.insert(requests, { messages = vim.deepcopy(messages), extra = extra })
      if #requests == 1 then
        callback({
          choices = {
            {
              message = {
                content = nil,
                tool_calls = {
                  {
                    id = "call_1",
                    type = "function",
                    ["function"] = {
                      name = "neocode__read_file",
                      arguments = vim.fn.json_encode({ path = "README.md" }),
                    },
                  },
                },
              },
            },
          },
        })
      else
        callback({
          choices = {
            { message = { content = "README says hello" } },
          },
          usage = { prompt_tokens = 20, completion_tokens = 4, total_tokens = 24 },
        })
      end
      return 77
    end

    local displayed = {}
    local completed_text = nil
    local_adapter.stream_with_tools({
      { role = "user", content = "read README" },
    }, nil, function(text)
      completed_text = text
    end, {
      tools = {
        { type = "function", ["function"] = { name = "neocode__read_file" } },
      },
      on_tool_call = function(tool_call, callback)
        assert.equals("call_1", tool_call.id)
        callback("README content", false)
      end,
      on_tool_display = function(tool_call, status, result)
        table.insert(displayed, { id = tool_call.id, status = status, result = result })
      end,
      on_round_start = function(round)
        assert.equals(2, round)
      end,
    })
    local_adapter._transport = nil

    assert.equals("README says hello", completed_text)
    assert.equals(2, #requests)
    assert.equals("assistant", requests[2].messages[2].role)
    assert.equals("call_1", requests[2].messages[2].tool_calls[1].id)
    assert.equals("tool", requests[2].messages[3].role)
    assert.equals("call_1", requests[2].messages[3].tool_call_id)
    assert.equals("README content", requests[2].messages[3].content)
    assert.equals("running", displayed[1].status)
    assert.equals("done", displayed[2].status)
  end)

  it("sanitizes assistant tool-call content before follow-up tool requests", function()
    local_adapter.setup({ model = "local-model", read_json = no_metadata_read })
    local requests = {}
    local_adapter._transport = function(messages, extra, callback)
      table.insert(requests, { messages = vim.deepcopy(messages), extra = extra })
      if #requests == 1 then
        callback({
          choices = {
            {
              message = {
                content = "<|channel>thought repeated-thought-thought-thought-thought Here is tool setup.",
                tool_calls = {
                  {
                    id = "call_1",
                    type = "function",
                    ["function"] = {
                      name = "neocode__read_file",
                      arguments = vim.fn.json_encode({ path = "README.md" }),
                    },
                  },
                },
              },
            },
          },
        })
      else
        callback({ choices = { { message = { content = "done" } } } })
      end
      return 77
    end

    local_adapter.stream_with_tools({
      { role = "user", content = "read README" },
    }, nil, function() end, {
      tools = {
        { type = "function", ["function"] = { name = "neocode__read_file" } },
      },
      on_tool_call = function(_, callback)
        callback("README content", false)
      end,
    })
    local_adapter._transport = nil

    assert.equals("Here is tool setup.", requests[2].messages[2].content)
  end)

  it("continues multi-round tool loops through write-file calls", function()
    local_adapter.setup({ model = "local-model", max_tool_rounds = 3, read_json = no_metadata_read })
    local requests = {}
    local_adapter._transport = function(messages, extra, callback)
      table.insert(requests, { messages = vim.deepcopy(messages), extra = extra })
      if #requests == 1 then
        callback({
          choices = {
            {
              message = {
                content = "I'll create the file.",
                tool_calls = {
                  {
                    id = "write_1",
                    type = "function",
                    ["function"] = {
                      name = "neocode__write_file",
                      arguments = vim.fn.json_encode({ path = "qa/example.lua", content = "return 42\n", create_dirs = true }),
                    },
                  },
                },
              },
            },
          },
        })
      elseif #requests == 2 then
        callback({
          choices = {
            {
              message = {
                content = "I'll verify it.",
                tool_calls = {
                  {
                    id = "read_1",
                    type = "function",
                    ["function"] = {
                      name = "neocode__read_file",
                      arguments = vim.fn.json_encode({ path = "qa/example.lua" }),
                    },
                  },
                },
              },
            },
          },
        })
      else
        callback({ choices = { { message = { content = "Created and verified." } } } })
      end
      return 77
    end

    local completed_text = nil
    local called = {}
    local_adapter.stream_with_tools({
      { role = "user", content = "Create qa/example.lua" },
    }, nil, function(text)
      completed_text = text
    end, {
      tools = {
        { type = "function", ["function"] = { name = "neocode__write_file" } },
        { type = "function", ["function"] = { name = "neocode__read_file" } },
      },
      on_tool_call = function(tool_call, callback)
        table.insert(called, tool_call.id)
        callback("ok", false)
      end,
    })
    local_adapter._transport = nil

    assert.same({ "write_1", "read_1" }, called)
    assert.equals(3, #requests)
    assert.equals("tool", requests[2].messages[3].role)
    assert.equals("tool", requests[3].messages[5].role)
    assert.equals("Created and verified.", completed_text)
  end)
end)
