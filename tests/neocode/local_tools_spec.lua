local local_tools = require("neocode.local_tools")

describe("local workspace tools", function()
  local tmp_dir

  before_each(function()
    tmp_dir = "/tmp/neocode_local_tools_" .. tostring(os.time()) .. "_" .. tostring(math.random(100000))
    vim.fn.mkdir(tmp_dir .. "/lua", "p")
    vim.fn.mkdir(tmp_dir .. "/.git", "p")
    vim.fn.writefile({ "# NeoCode", "local workspace search tools" }, tmp_dir .. "/README.md")
    vim.fn.writefile({ "return { search = true }" }, tmp_dir .. "/lua/init.lua")
    vim.fn.writefile({ "ignored" }, tmp_dir .. "/.git/config")
  end)

  after_each(function()
    vim.fn.delete(tmp_dir, "rf")
  end)

  it("returns compact OpenAI function schemas", function()
    local schemas = local_tools.get_tools()
    local names = {}
    for _, schema in ipairs(schemas) do
      table.insert(names, schema["function"].name)
    end

    assert.same({ "neocode__read_file", "neocode__list_directory", "neocode__search_files" }, names)
    assert.equals("function", schemas[1].type)
    assert.is_not_nil(schemas[1]["function"].parameters.properties.path)
  end)

  it("reads files relative to the workspace root", function()
    local result, is_error = local_tools.execute({
      ["function"] = {
        name = "neocode__read_file",
        arguments = vim.fn.json_encode({ path = "README.md" }),
      },
    }, { cwd = tmp_dir })

    assert.is_false(is_error)
    assert.is_truthy(result:find("# NeoCode", 1, true))
  end)

  it("rejects reads outside the workspace root", function()
    local result, is_error = local_tools.execute({
      ["function"] = {
        name = "neocode__read_file",
        arguments = vim.fn.json_encode({ path = "/etc/passwd" }),
      },
    }, { cwd = tmp_dir })

    assert.is_true(is_error)
    assert.is_truthy(result:find("outside workspace", 1, true))
  end)

  it("lists directories without noisy ignored entries", function()
    local result, is_error = local_tools.execute({
      ["function"] = {
        name = "neocode__list_directory",
        arguments = vim.fn.json_encode({ path = "." }),
      },
    }, { cwd = tmp_dir })

    assert.is_false(is_error)
    assert.is_truthy(result:find("README.md", 1, true))
    assert.is_truthy(result:find("lua/", 1, true))
    assert.is_nil(result:find(".git", 1, true))
  end)

  it("searches text files and returns file line matches", function()
    local result, is_error = local_tools.execute({
      ["function"] = {
        name = "neocode__search_files",
        arguments = vim.fn.json_encode({ query = "search", path = ".", max_results = 10 }),
      },
    }, { cwd = tmp_dir })

    assert.is_false(is_error)
    assert.is_truthy(result:find("README.md:2:", 1, true))
    assert.is_truthy(result:find("lua/init.lua:1:", 1, true))
  end)

  it("caps search results and scanned files", function()
    for i = 1, 25 do
      vim.fn.writefile({ "needle " .. i }, tmp_dir .. "/file" .. i .. ".txt")
    end

    local result, is_error = local_tools.execute({
      ["function"] = {
        name = "neocode__search_files",
        arguments = vim.fn.json_encode({ query = "missing", path = ".", max_results = 9999, max_files = 3 }),
      },
    }, { cwd = tmp_dir })

    assert.is_false(is_error)
    assert.is_truthy(result:find("searched 3 files", 1, true))
  end)
end)
