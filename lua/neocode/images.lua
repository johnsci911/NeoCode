local M = {}

-- Detect which clipboard-to-image tool is available on this system
function M.detect_tool()
  local is_mac   = vim.fn.has("mac") == 1
  local is_linux = vim.fn.has("linux") == 1

  if is_mac and vim.fn.executable("pngpaste") == 1 then
    return "pngpaste"
  elseif is_linux then
    if vim.fn.executable("wl-paste") == 1 then return "wl-paste" end
    if vim.fn.executable("xclip") == 1    then return "xclip"    end
  end
  return nil
end

-- Generate a unique temp file path for a session image
function M.temp_path(data_dir, session_id)
  local dir = data_dir .. "/" .. session_id
  vim.fn.mkdir(dir, "p")
  return dir .. "/" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999)) .. ".png"
end

-- Save clipboard image to a temp file using the detected tool.
-- Returns: path (string) on success, or nil + error_message on failure.
function M.save_clipboard(data_dir, session_id)
  local tool = M.detect_tool()
  if not tool then
    return nil, "neocode: no image paste tool found (install pngpaste on macOS, wl-paste or xclip on Linux)"
  end

  local path = M.temp_path(data_dir, session_id)
  local cmd

  if tool == "pngpaste" then
    cmd = "pngpaste " .. vim.fn.shellescape(path)
  elseif tool == "wl-paste" then
    cmd = "wl-paste --type image/png > " .. vim.fn.shellescape(path)
  elseif tool == "xclip" then
    cmd = "xclip -selection clipboard -t image/png -o > " .. vim.fn.shellescape(path)
  end

  local result = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    vim.fn.delete(path)
    return nil, "neocode: failed to capture clipboard image: " .. (result or "")
  end

  return path, nil
end

-- Delete a single temp image file
function M.delete_temp(path)
  if path and vim.fn.filereadable(path) == 1 then
    vim.fn.delete(path)
  end
end

-- Wipe the entire image folder for a session (called on session close)
function M.cleanup_session(data_dir, session_id)
  local dir = data_dir .. "/" .. session_id
  if vim.fn.isdirectory(dir) == 1 then
    vim.fn.delete(dir, "rf")
  end
end

-- On startup: delete image folders for sessions no longer in sessions.json
function M.cleanup_stale(data_dir, live_session_ids)
  local images_dir = data_dir
  if vim.fn.isdirectory(images_dir) == 0 then return end

  local uv = vim.uv or vim.loop
  local handle = uv.fs_scandir(images_dir)
  if not handle then return end

  local live = {}
  for _, id in ipairs(live_session_ids) do live[id] = true end

  while true do
    local name, kind = uv.fs_scandir_next(handle)
    if not name then break end
    if kind == "directory" and not live[name] then
      vim.fn.delete(images_dir .. "/" .. name, "rf")
    end
  end
end

-- Paste image from clipboard into the current session.
-- Stores path on session.pending_image; deleted on session close.
function M.paste(adapter, session, config)
  if not session then
    vim.notify("neocode: no active session", vim.log.levels.WARN)
    return
  end

  local path, err = M.save_clipboard(config.data_dir .. "/images", session.id)
  if not path then
    vim.notify(err, vim.log.levels.ERROR)
    return
  end

  adapter.attach_image(session, path)
  session.pending_image = path
end

return M
