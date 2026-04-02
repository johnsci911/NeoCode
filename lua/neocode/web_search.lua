-- lua/neocode/web_search.lua
-- Lightweight web search via DuckDuckGo (no API key needed)
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
  "search for", "look up", "find out",
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
  -- Remove common prefixes
  local q = text:gsub("^%s*@web%s*", "")
  -- Trim to reasonable length for search
  if #q > 200 then
    q = q:sub(1, 200)
  end
  return q
end

-- Fetch search results from DuckDuckGo HTML lite (synchronous, called via jobstart)
-- Returns formatted string of search results
function M.search(query, callback)
  local encoded = query:gsub(" ", "+"):gsub("[^%w%+%.%-_]", function(c)
    return string.format("%%%02X", string.byte(c))
  end)

  local url = "https://html.duckduckgo.com/html/?q=" .. encoded
  local result_lines = {}

  vim.fn.jobstart({
    "curl", "--silent", "--max-time", "5",
    "-H", "User-Agent: Mozilla/5.0",
    url,
  }, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          table.insert(result_lines, line)
        end
      end
    end,
    on_exit = function()
      local html = table.concat(result_lines, "\n")
      local results = M._parse_results(html)
      vim.schedule(function()
        callback(results)
      end)
    end,
  })
end

-- Parse DuckDuckGo HTML lite results
function M._parse_results(html)
  local results = {}
  local count = 0
  local max_results = 5

  -- Extract result snippets from DuckDuckGo HTML lite
  -- Each result has class "result__snippet"
  for snippet in html:gmatch('<a class="result__snippet"[^>]*>(.-)</a>') do
    count = count + 1
    if count > max_results then break end
    -- Strip HTML tags
    local text = snippet:gsub("<[^>]+>", ""):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&#x27;", "'"):gsub("&nbsp;", " ")
    text = text:gsub("%s+", " "):match("^%s*(.-)%s*$")
    if text and text ~= "" then
      table.insert(results, text)
    end
  end

  -- Also grab titles
  local titles = {}
  count = 0
  for title in html:gmatch('<a class="result__a"[^>]*>(.-)</a>') do
    count = count + 1
    if count > max_results then break end
    local text = title:gsub("<[^>]+>", ""):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&#x27;", "'"):gsub("&nbsp;", " ")
    text = text:gsub("%s+", " "):match("^%s*(.-)%s*$")
    if text and text ~= "" then
      table.insert(titles, text)
    end
  end

  -- Combine titles and snippets
  local formatted = {}
  for i = 1, math.min(#titles, #results) do
    table.insert(formatted, string.format("[%d] %s\n%s", i, titles[i], results[i]))
  end

  if #formatted == 0 then
    return nil
  end

  return table.concat(formatted, "\n\n")
end

-- Format search results as context for the LLM
function M.format_context(query, results)
  return string.format(
    "The following are recent web search results for: \"%s\"\n\n%s\n\nUse these search results to inform your answer. Cite the results where relevant.",
    query, results
  )
end

return M
