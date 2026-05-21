local llama = require("neocode.adapters.llama")

describe("llama adapter text tool-call parsing", function()
  it("parses Claude-style XML function calls", function()
    local text = table.concat({
      "Yes, I can read this project.",
      "",
      "<function=filesystem__list_directory>",
      "<parameter=path>",
      "/Users/johnkarlo/Desktop/NeoCode",
      "</parameter>",
      "</function>",
    }, "\n")

    local clean_text, tool_calls = llama._parse_text_tool_calls(text)

    assert.equals("Yes, I can read this project.", clean_text)
    assert.equals(1, #tool_calls)
    assert.equals("filesystem__list_directory", tool_calls[1]["function"].name)

    local args = vim.fn.json_decode(tool_calls[1]["function"].arguments)
    assert.equals("/Users/johnkarlo/Desktop/NeoCode", args.path)
  end)
end)
