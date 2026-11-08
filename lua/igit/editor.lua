local M = {}
local api = vim.api
local prefix = "\027]51;igit-edit;"

local function editor_window(session)
  local function usable(win)
    return win and api.nvim_win_is_valid(win)
      and api.nvim_win_get_config(win).relative == ""
      and vim.bo[api.nvim_win_get_buf(win)].buftype ~= "terminal"
  end
  if usable(session.source_win) then
    return session.source_win, false
  end
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if usable(win) then
      return win, false
    end
  end
  vim.cmd("belowright new")
  return api.nvim_get_current_win(), true
end

local function edit(session, path, hide)
  if session.deleted or not session.win or not api.nvim_win_is_valid(session.win)
      or api.nvim_get_current_win() ~= session.win then
    return -- A delayed request must not steal focus from another editor/window.
  end
  local stat = vim.uv.fs_stat(path)
  assert(stat and stat.type == "file", "Working file is unavailable")
  vim.cmd.stopinsert()
  local win, created = editor_window(session)
  local ok, result = pcall(api.nvim_win_call, win, function()
    -- Reuse loaded buffers, including their unsaved text. A numeric :buffer
    -- switch preserves the user's normal 'hidden' / modified-buffer guards.
    local buf = vim.fn.bufadd(path)
    assert(buf > 0, "Could not create the file buffer")
    vim.cmd("buffer " .. buf)
    vim.bo[buf].buflisted = true
    return buf
  end)
  if not ok then
    if created and api.nvim_win_is_valid(win) then
      pcall(api.nvim_win_close, win, true)
    end
    error(result, 0)
  end
  if session.window.layout == "float" then
    hide(session)
  end
  session.source_win, session.source_buf = win, result
  api.nvim_set_current_win(win)
end

function M.request(event, session, hide)
  if not session or not session.token then
    return
  end
  -- Nvim 0.10 supplies the string directly; later versions use .sequence.
  local sequence = type(event.data) == "table" and event.data.sequence or event.data
  if type(sequence) ~= "string" or sequence:sub(1, #prefix) ~= prefix then
    return
  end
  local ok, request = pcall(vim.json.decode, sequence:sub(#prefix + 1))
  if not ok or type(request) ~= "table" or request.version ~= 1
      or request.session ~= session.token or type(request.path) ~= "string"
      or request.path:find("\0", 1, true)
      or not (request.path:match("^/") or request.path:match("^%a:[/\\]") or request.path:match("^\\\\")) then
    return
  end
  vim.schedule(function()
    local edited, err = pcall(edit, session, request.path, hide)
    if not edited then
      if not session.exited and session.win and api.nvim_win_is_valid(session.win)
          and api.nvim_get_current_win() == session.win then
        vim.cmd.startinsert()
      end
      vim.notify("Could not edit file: " .. tostring(err), vim.log.levels.ERROR, { title = "igit.nvim" })
    end
  end)
end

return M
