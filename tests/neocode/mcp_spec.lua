-- tests/neocode/mcp_spec.lua
local mcp = require("neocode.mcp")

describe("mcp schema formatting", function()
  it("formats a tool as OpenAI function schema", function()
    local tool = {
      name = "read_file",
      description = "Read a file",
      inputSchema = {
        type = "object",
        properties = {
          path = { type = "string", description = "File path" },
        },
        required = { "path" },
      },
      server_name = "filesystem",
    }
    local schema = mcp._format_tool_schema(tool)
    assert.equals("function", schema.type)
    assert.equals("filesystem__read_file", schema["function"].name)
    assert.equals("Read a file", schema["function"].description)
    assert.is_not_nil(schema["function"].parameters.properties.path)
  end)

  it("formats a resource as OpenAI function schema", function()
    local resource = {
      uri = "file:///project/README.md",
      name = "README",
      description = "Project readme",
      server_name = "filesystem",
    }
    local schema = mcp._format_resource_schema(resource)
    assert.equals("function", schema.type)
    assert.is_truthy(schema["function"].name:find("^mcp_resource__"))
    assert.is_truthy(schema["function"].description:find("README"))
  end)

  it("formats a prompt as OpenAI function schema", function()
    local prompt = {
      name = "code_review",
      description = "Review code",
      arguments = {
        { name = "file", description = "File to review", required = true },
      },
      server_name = "codetools",
    }
    local schema = mcp._format_prompt_schema(prompt)
    assert.equals("function", schema.type)
    assert.is_truthy(schema["function"].name:find("^mcp_prompt__"))
    assert.is_not_nil(schema["function"].parameters.properties.file)
  end)

  it("parses namespaced tool name back to server and tool", function()
    local server, tool = mcp._parse_tool_name("filesystem__read_file")
    assert.equals("filesystem", server)
    assert.equals("read_file", tool)
  end)

  it("parses resource tool name back to server and uri", function()
    local server, uri = mcp._parse_resource_name("mcp_resource__filesystem__file____project__README_md")
    assert.equals("filesystem", server)
    assert.is_not_nil(uri)
  end)

  it("parses prompt tool name back to server and prompt", function()
    local server, prompt = mcp._parse_prompt_name("mcp_prompt__codetools__code_review")
    assert.equals("codetools", server)
    assert.equals("code_review", prompt)
  end)
end)
