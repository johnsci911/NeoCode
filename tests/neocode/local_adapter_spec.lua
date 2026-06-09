local neocode = require("neocode")
local local_adapter = require("neocode.adapters.local")

describe("local adapter", function()
  before_each(function()
    local_adapter.setup({})
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
    local_adapter.setup({})

    assert.equals("http://127.0.0.1:8080/v1", local_adapter.config.base_url)
    assert.equals("openai_compatible", local_adapter.config.provider)
    assert.equals(32768, local_adapter.config.context_size)
  end)

  it("can prefer llama-server provider enhancements", function()
    local_adapter.setup({
      provider = "llama_server",
      base_url = "http://127.0.0.1:8080/v1",
      model = "local-model",
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
        }
      end,
    })

    local ok, message = local_adapter.set_thinking("medium")
    assert.is_true(ok)
    assert.equals("thinking mode: medium", message)

    local payload = local_adapter._request_payload({
      { role = "user", content = "think" },
    })

    assert.is_true(payload.enable_thinking)
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

  it("builds OpenAI chat completion payloads with tools when provided", function()
    local_adapter.setup({ model = "local-model", temperature = 0.1, max_tokens = 123 })

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

  it("sanitizes corrupted assistant history before building request payloads", function()
    local_adapter.setup({ model = "local-model" })

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
    local_adapter.setup({ provider = "llama_server", model = "local-model", context_size = 24576 })

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

  it("strips leaked local thinking and chat-template preambles from responses", function()
    local_adapter.setup({ provider = "llama_server", model = "local-model" })

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
    local_adapter.setup({ provider = "llama_server", model = "local-model" })

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
    local_adapter.setup({ provider = "llama_server", model = "local-model" })

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

  it("executes tool calls and continues with tool results", function()
    local_adapter.setup({ model = "local-model" })
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
    local_adapter.setup({ model = "local-model" })
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
    local_adapter.setup({ model = "local-model", max_tool_rounds = 3 })
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
