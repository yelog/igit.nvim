local M = {}
local api = vim.api
local edit_prefix = "\027]51;igit-edit;"
local revision_prefix = "\027]51;igit-show-revision;"
local max_revision_size = 512 * 1024
local git_timeout = 15000

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

local function owns_focus(session)
  return session and not session.deleted and session.win
    and api.nvim_win_is_valid(session.win)
    and api.nvim_win_get_buf(session.win) == session.buf
    and api.nvim_get_current_win() == session.win
end

local function recover(session, message)
  if not owns_focus(session) then
    return
  end
  if not session.exited then
    pcall(vim.cmd.startinsert)
  end
  vim.notify(message, vim.log.levels.ERROR, { title = "igit.nvim" })
end

local function open_buffer(session, buf, hide)
  if not owns_focus(session) then
    return
  end
  vim.cmd.stopinsert()
  local win, created = editor_window(session)
  local ok, result = pcall(api.nvim_win_call, win, function()
    vim.cmd("buffer " .. buf)
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

local function edit(session, path, hide)
  if not owns_focus(session) then
    return
  end
  local stat = vim.uv.fs_stat(path)
  assert(stat and stat.type == "file", "Working file is unavailable")
  open_buffer(session, vim.fn.bufadd(path), hide)
  vim.bo[session.source_buf].buflisted = true
end

local function valid_absolute_path(path)
  return type(path) == "string"
    and not path:find("\0", 1, true)
    and (path:match("^/") or path:match("^%a:[/\\]") or path:match("^\\\\"))
end

local function valid_git_path(path)
  if type(path) ~= "string" or path == "" or path:find("\0", 1, true)
      or path:sub(1, 1) == "/" or path:match("^%a:[/\\]") or path:match("^\\\\") then
    return false
  end
  for component in path:gmatch("[^/]+") do
    if component == ".." then
      return false
    end
  end
  return true
end

local function valid_revision(revision)
  return type(revision) == "string"
    and (#revision == 40 or #revision == 64) and revision:match("^%x+$") ~= nil
end

local function valid_revision_request(request, session)
  return type(request) == "table" and request.version == 1
    and request.session == session.token
    and valid_absolute_path(request.repo)
    and valid_git_path(request.path)
    and valid_revision(request.revision)
end

local function valid_utf8(value)
  local index = 1
  while index <= #value do
    local byte = value:byte(index)
    local length
    if byte <= 0x7f then
      length = 1
    elseif byte >= 0xc2 and byte <= 0xdf then
      length = 2
    elseif byte >= 0xe0 and byte <= 0xef then
      length = 3
    elseif byte >= 0xf0 and byte <= 0xf4 then
      length = 4
    else
      return false
    end
    if index + length - 1 > #value then
      return false
    end
    for offset = 1, length - 1 do
      local continuation = value:byte(index + offset)
      if continuation < 0x80 or continuation > 0xbf then
        return false
      end
    end
    local second = value:byte(index + 1)
    if length == 3 and ((byte == 0xe0 and second < 0xa0) or (byte == 0xed and second >= 0xa0)) then
      return false
    end
    if length == 4 and ((byte == 0xf0 and second < 0x90) or (byte == 0xf4 and second >= 0x90)) then
      return false
    end
    index = index + length
  end
  return true
end

local function revision_title(path, revision)
  local filename = path:match("([^/]+)$") or path
  return filename .. " (" .. revision:sub(1, 8) .. ")"
end

local function revision_name(repo, path, revision)
  local identity = vim.fn.sha256(vim.json.encode({ repo, path, revision }))
  return "igit://revision/" .. identity .. "/" .. revision .. "/" .. revision_title(path, revision)
end

local function revision_metadata_matches(buf, repo, path, revision)
  local metadata = vim.b[buf].igit_revision
  return type(metadata) == "table" and metadata.repo == repo
    and metadata.path == path and metadata.revision == revision
end

local function loaded_revision(name, repo, path, revision)
  local buf = vim.fn.bufnr(name)
  if buf > 0 and api.nvim_buf_is_valid(buf) and api.nvim_buf_is_loaded(buf)
      and revision_metadata_matches(buf, repo, path, revision) then
    vim.bo[buf].buflisted = true
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].undofile = false
    vim.bo[buf].readonly = true
    vim.bo[buf].modifiable = false
    return buf
  end
end

local function set_revision_content(buf, content)
  local lines = vim.split(content, "\n", { plain = true })
  local boundary_count = #lines - 1
  local dos = boundary_count > 0
  for index = 1, boundary_count do
    if lines[index]:sub(-1) ~= "\r" then
      dos = false
      break
    end
  end
  if dos then
    for index = 1, boundary_count do
      lines[index] = lines[index]:sub(1, -2)
    end
  end
  local endofline = content:sub(-1) == "\n"
  if endofline then
    table.remove(lines)
  end
  if #lines == 0 then
    lines = { "" }
  end
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].endofline = endofline
  vim.bo[buf].fixendofline = false
  vim.bo[buf].fileencoding = "utf-8"
  vim.bo[buf].fileformat = dos and "dos" or "unix"
  vim.bo[buf].modified = false
  vim.bo[buf].readonly = true
  vim.bo[buf].modifiable = false
end

local function configure_revision_buffer(name, repo, path, revision, content)
  local existing = vim.fn.bufnr(name)
  if existing > 0 and api.nvim_buf_is_valid(existing) and api.nvim_buf_is_loaded(existing) then
    if revision_metadata_matches(existing, repo, path, revision) then
      vim.bo[existing].buflisted = true
      vim.bo[existing].buftype = "nofile"
      vim.bo[existing].bufhidden = "hide"
      vim.bo[existing].swapfile = false
      vim.bo[existing].undofile = false
      vim.bo[existing].readonly = true
      vim.bo[existing].modifiable = false
      return existing
    end
    error("A different buffer already uses this revision identity", 0)
  end
  local buf = existing > 0 and existing or vim.fn.bufadd(name)
  if buf <= 0 or not api.nvim_buf_is_valid(buf) then
    error("Could not create the revision buffer", 0)
  end
  vim.bo[buf].buflisted = true
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].undofile = false
  set_revision_content(buf, content)
  local filetype = vim.filetype.match({ filename = path })
  vim.bo[buf].filetype = filetype or ""
  vim.bo[buf].swapfile = false
  vim.bo[buf].readonly = true
  vim.bo[buf].modifiable = false
  vim.b[buf].igit_revision = {
    repo = repo,
    path = path,
    revision = revision,
    title = revision_title(path, revision),
  }
  return buf
end

local function git_command(repo, arguments, callback)
  local argv = { "git", "-C", repo }
  vim.list_extend(argv, arguments)
  local ok, process = pcall(vim.system, argv, {
    text = false,
    timeout = git_timeout,
    env = { GIT_OPTIONAL_LOCKS = "0", GIT_NO_LAZY_FETCH = "1" },
  }, function(result)
    vim.schedule(function()
      callback(result)
    end)
  end)
  if not ok then
    vim.schedule(function()
      callback({ code = -1, stdout = "", stderr = tostring(process) })
    end)
  end
end

local function git_error(result)
  local message = (result.stderr or ""):gsub("%s+$", "")
  if message ~= "" then
    return message:match("([^\n]+)") or message
  end
  return "Git exited with code " .. tostring(result.code or -1)
end

local function revision_current(session, request_id, request_win)
  return request_id == session.revision_request and session.win == request_win
    and owns_focus(session)
end

local function read_revision(session, request_id, request_win, hide, repo, path, revision)
  local object = revision .. ":" .. path
  local function fail(message)
    recover(session, "Could not show file revision: " .. message)
  end
  local function read_blob()
    git_command(repo, { "cat-file", "-s", object }, function(size_result)
      if not revision_current(session, request_id, request_win) then
        return
      end
      local size = tonumber((size_result.stdout or ""):match("^%s*(%d+)%s*$"))
      if size_result.code ~= 0 or not size then
        return fail(git_error(size_result))
      end
      if size > max_revision_size then
        return fail("blob exceeds 512 KiB")
      end
      git_command(repo, { "cat-file", "blob", object }, function(blob_result)
        if not revision_current(session, request_id, request_win) then
          return
        end
        if blob_result.code ~= 0 then
          return fail(git_error(blob_result))
        end
        local content = blob_result.stdout or ""
        if #content > max_revision_size then
          return fail("blob exceeds 512 KiB")
        end
        if content:find("\0", 1, true) then
          return fail("file contains binary data")
        end
        if not valid_utf8(content) then
          return fail("file is not valid UTF-8")
        end
        local name = revision_name(repo, path, revision)
        local opened, err = pcall(function()
          local buf = configure_revision_buffer(name, repo, path, revision, content)
          open_buffer(session, buf, hide)
        end)
        if not opened then
          fail(tostring(err))
        end
      end)
    end)
  end
  git_command(repo, { "cat-file", "-t", object }, function(type_result)
    if not revision_current(session, request_id, request_win) then
      return
    end
    if type_result.code ~= 0 then
      return fail(git_error(type_result))
    end
    local kind = (type_result.stdout or ""):gsub("%s+$", "")
    if kind ~= "blob" then
      return fail("path is not a file at that revision")
    end
    read_blob()
  end)
end

local function show_revision(session, request, hide, request_id, request_win)
  if not revision_current(session, request_id, request_win) then
    return
  end
  local repo = vim.uv.fs_realpath(request.repo)
  local stat = repo and vim.uv.fs_stat(repo)
  if not stat or stat.type ~= "directory" then
    return recover(session, "Could not show file revision: repository is unavailable")
  end
  local name = revision_name(repo, request.path, request.revision)
  local existing = loaded_revision(name, repo, request.path, request.revision)
  if existing then
    local ok, err = pcall(open_buffer, session, existing, hide)
    if not ok then
      recover(session, "Could not show file revision: " .. tostring(err))
    end
    return
  end
  read_revision(session, request_id, request_win, hide, repo, request.path, request.revision)
end

local function decoded_request(sequence, prefix)
  if sequence:sub(1, #prefix) ~= prefix then
    return
  end
  local ok, request = pcall(vim.json.decode, sequence:sub(#prefix + 1))
  if ok and type(request) == "table" then
    return request
  end
end

local function event_sequence(event)
  local sequence = type(event.data) == "table" and event.data.sequence or event.data
  if type(sequence) ~= "string" then
    return
  end
  return (sequence:gsub("\a+$", ""))
end

function M.request(event, session, hide)
  if not session or not session.token then
    return
  end
  local sequence = event_sequence(event)
  if not sequence then
    return
  end
  local edit_request = decoded_request(sequence, edit_prefix)
  if edit_request then
    if edit_request.version ~= 1 or edit_request.session ~= session.token
        or type(edit_request.path) ~= "string"
        or edit_request.path:find("\0", 1, true)
        or not valid_absolute_path(edit_request.path) then
      return
    end
    vim.schedule(function()
      local edited, err = pcall(edit, session, edit_request.path, hide)
      if not edited then
        recover(session, "Could not edit file: " .. tostring(err))
      end
    end)
    return
  end
  local revision_request = decoded_request(sequence, revision_prefix)
  if not valid_revision_request(revision_request, session) then
    return
  end
  if not owns_focus(session) then
    return
  end
  session.revision_request = (session.revision_request or 0) + 1
  local request_id = session.revision_request
  local request_win = session.win
  vim.schedule(function()
    show_revision(session, revision_request, hide, request_id, request_win)
  end)
end

return M
