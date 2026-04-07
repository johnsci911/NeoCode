-- lua/neocode/web_search.lua
-- Web search via DuckDuckGo (using Python ddgs library)
local M = {}

-- Keywords/patterns that suggest the user needs current information
local SEARCH_PATTERNS = {
  "latest", "newest", "recent", "current", "today",
  "news", "update", "release", "announce",
  "what is", "what are", "who is", "who are",
  "how to", "how do", "how does",
  "when is", "when did", "when will",
  "where is", "where can",
  "price of", "cost of", "weather",
  "2024", "2025", "2026", "2027",
  "right now", "this week", "this month", "this year",
  "search for", "search the", "look up", "find out",
  "browse", "@web",
}

-- Check if a message likely needs web search
function M.needs_search(text)
  local lower = text:lower()
  for _, pattern in ipairs(SEARCH_PATTERNS) do
    if lower:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

-- Extract a search query from the user's message
function M.extract_query(text)
  local q = text:gsub("^%s*@web%s*", "")
  if #q > 200 then q = q:sub(1, 200) end
  return q
end

-- Path to the venv Python
local _venv_dir = vim.fn.stdpath("data") .. "/neocode/search_venv"
local _python = _venv_dir .. "/bin/python"

-- Ensure the Python venv and duckduckgo-search are installed
function M._ensure_deps(callback)
  if vim.fn.executable(_python) == 1 then
    callback(true)
    return
  end

  vim.notify("neocode: setting up web search (one-time)...", vim.log.levels.INFO)

  vim.fn.jobstart({
    "python3", "-m", "venv", _venv_dir,
  }, {
    on_exit = function(_, code)
      if code ~= 0 then
        vim.schedule(function()
          vim.notify("neocode: failed to create Python venv", vim.log.levels.ERROR)
        end)
        callback(false)
        return
      end
      vim.fn.jobstart({
        _venv_dir .. "/bin/pip", "install", "-q", "ddgs",
      }, {
        on_exit = function(_, pip_code)
          vim.schedule(function()
            if pip_code == 0 then
              vim.notify("neocode: web search ready!", vim.log.levels.INFO)
              callback(true)
            else
              vim.notify("neocode: failed to install duckduckgo-search", vim.log.levels.ERROR)
              callback(false)
            end
          end)
        end,
      })
    end,
  })
end

-- Fetch search results using Python duckduckgo-search
function M.search(query, callback)
  M._ensure_deps(function(ok)
    if not ok then
      callback(nil)
      return
    end

    local script = string.format([[
import json, sys
try:
    try:
        from ddgs import DDGS
    except ImportError:
        from duckduckgo_search import DDGS
    results = DDGS().text(%s, max_results=5)
    out = []
    for r in results:
        out.append({"title": r.get("title",""), "body": r.get("body",""), "href": r.get("href","")})
    print(json.dumps(out))
except Exception as e:
    print(json.dumps({"error": str(e)}))
]], vim.fn.json_encode(query))

    local output_lines = {}
    vim.fn.jobstart({
      _python, "-c", script,
    }, {
      stdout_buffered = true,
      on_stdout = function(_, data)
        if data then
          for _, line in ipairs(data) do
            if line ~= "" then table.insert(output_lines, line) end
          end
        end
      end,
      on_exit = function()
        vim.schedule(function()
          local raw = table.concat(output_lines, "")
          if raw == "" then
            callback(nil)
            return
          end
          local ok_json, parsed = pcall(vim.fn.json_decode, raw)
          if not ok_json or type(parsed) ~= "table" then
            callback(nil)
            return
          end
          if parsed.error then
            vim.notify("neocode: search error: " .. parsed.error, vim.log.levels.WARN)
            callback(nil)
            return
          end

          -- Format results (limit body length to prevent context overflow)
          local formatted = {}
          for i, r in ipairs(parsed) do
            local body = r.body or ""
            if #body > 300 then body = body:sub(1, 300) .. "..." end
            table.insert(formatted, string.format("[%d] %s\n%s\nURL: %s", i, r.title, body, r.href))
            if i >= 3 then break end -- max 3 results to save context
          end

          if #formatted == 0 then
            callback(nil)
            return
          end

          callback(table.concat(formatted, "\n\n"))
        end)
      end,
    })
  end)
end

-- Format search results as context for the LLM
function M.format_context(query, results)
  return string.format(
    "The following are web search results for: \"%s\"\n\n%s\n\nUse these search results to provide an accurate, up-to-date answer. Cite the source numbers [1], [2], etc. where relevant.",
    query, results
  )
end

return M
