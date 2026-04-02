-- lua/neocode/llama_session.lua
local M = {}

function M._path(data_dir, session_id)
  return data_dir .. "/" .. session_id .. ".json"
end

function M.save(data_dir, session_id, messages)
  vim.fn.mkdir(data_dir, "p")
  local path = M._path(data_dir, session_id)
  local ok, encoded = pcall(vim.fn.json_encode, messages)
  if not ok then return end
  local f = io.open(path, "w")
  if f then
    f:write(encoded)
    f:close()
  end
end

function M.load(data_dir, session_id)
  local path = M._path(data_dir, session_id)
  local f = io.open(path, "r")
  if not f then return {} end
  local raw = f:read("*a")
  f:close()
  local ok, data = pcall(vim.fn.json_decode, raw)
  if ok and type(data) == "table" then return data end
  return {}
end

function M.list(data_dir)
  local results = {}
  local uv = vim.uv or vim.loop
  local handle = uv.fs_scandir(data_dir)
  if not handle then return results end
  while true do
    local name, kind = uv.fs_scandir_next(handle)
    if not name then break end
    if kind == "file" and name:match("%.json$") then
      table.insert(results, (name:gsub("%.json$", "")))
    end
  end
  return results
end

function M.delete(data_dir, session_id)
  local path = M._path(data_dir, session_id)
  vim.fn.delete(path)
end

return M
