local M = {}
local api = vim.api
local uv = vim.uv
local disk = {}
local tracked = setmetatable({}, { __mode = "k" })
local hash_limit = 1024 * 1024

local function working_file(buf)
  return api.nvim_buf_is_valid(buf) and api.nvim_buf_is_loaded(buf)
    and vim.bo[buf].buftype == "" and api.nvim_buf_get_name(buf) ~= ""
end

local function canonical(path)
  return vim.fs.normalize(uv.fs_realpath(path) or path)
end

local function repository(path)
  local directory = path
  while directory do
    if uv.fs_stat(directory .. "/.git") then
      return canonical(directory)
    end
    local parent = vim.fs.dirname(directory)
    if parent == directory then
      break
    end
    directory = parent
  end
end

local function fingerprint(path)
  local descriptor, open_error = uv.fs_open(path, "r", 0)
  if not descriptor then
    return { error = tostring(open_error) }
  end
  local stat = uv.fs_fstat(descriptor)
  if stat and stat.type == "file" and stat.size > hash_limit then
    uv.fs_close(descriptor)
    return {
      size = stat.size, mode = stat.mode, mtime = stat.mtime, ctime = stat.ctime,
      dev = stat.dev, ino = stat.ino,
    }
  end
  local bytes = stat and stat.type == "file" and (stat.size == 0 and "" or uv.fs_read(descriptor, stat.size, 0))
  uv.fs_close(descriptor)
  if not bytes or #bytes ~= stat.size then
    return { error = "File is unavailable" }
  end
  return { size = stat.size, hash = vim.fn.sha256(bytes), mode = stat.mode }
end

local function within(path, root)
  local prefix = root:sub(-1) == "/" and root or root .. "/"
  return path == root or path:sub(1, #prefix) == prefix
end

local function included(path, roots)
  for root in pairs(roots or {}) do
    if within(path, root) then
      return true
    end
  end
  return false
end

local function remember(buf)
  if working_file(buf) then
    local name = api.nvim_buf_get_name(buf)
    local path = canonical(name)
    for session in pairs(tracked) do
      if not session.deleted and not session.exited and included(path, session.sync_roots) then
        disk[buf] = { name = name, value = fingerprint(name) }
        return
      end
    end
  end
end

function M.capture(session)
  session.sync_roots = session.sync_roots or {}
  local cwd = canonical(session.cwd)
  session.sync_roots[cwd] = true
  local root = repository(cwd)
  if root then
    session.sync_roots[root] = true
  end
  tracked[session] = true
  session.disk = {}
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if working_file(buf) and included(canonical(api.nvim_buf_get_name(buf)), session.sync_roots) then
      local name = api.nvim_buf_get_name(buf)
      local previous = disk[buf]
      local value = previous and previous.name == name and previous.value or fingerprint(name)
      session.disk[buf] = { name = name, value = value }
      disk[buf] = { name = name, value = value }
    end
  end
end

function M.reconcile(session, repo)
  local roots = repo and { [repo] = true } or session.sync_roots or { [canonical(session.cwd)] = true }
  local repositories = {}
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if working_file(buf) then
      local name = api.nvim_buf_get_name(buf)
      local path = canonical(name)
      if included(path, roots) then
        local before = disk[buf] or session.disk and session.disk[buf]
        before = before and before.name == name and before.value or nil
        local after = fingerprint(name)
        if vim.bo[buf].modified then
          if before and not vim.deep_equal(before, after) then
            vim.notify("File changed on disk; unsaved buffer kept: " .. name .. ". Review before saving.",
              vim.log.levels.WARN, { title = "igit.nvim" })
          end
        else
          local autoread = vim.bo[buf].autoread
          vim.bo[buf].autoread = true
          local checked, check_error = pcall(api.nvim_buf_call, buf, function()
            vim.cmd("silent checktime " .. buf)
          end)
          if api.nvim_buf_is_valid(buf) then
            vim.bo[buf].autoread = autoread
          end
          if not checked then
            vim.notify("Could not check file changes: " .. tostring(check_error),
              vim.log.levels.WARN, { title = "igit.nvim" })
          end
        end
        session.disk = session.disk or {}
        session.disk[buf] = { name = name, value = after }
        disk[buf] = { name = name, value = after }
        local root = repository(vim.fs.dirname(path))
        if root then
          repositories[root] = true
        end
      end
    end
  end
  if repo then
    repositories[repo] = true
  end
  for root in pairs(roots) do
    local found = repository(root)
    if found then
      repositories[found] = true
    end
  end
  for root in pairs(repositories) do
    api.nvim_exec_autocmds("User", {
      pattern = "IgitChanged", modeline = false, data = { repo = root, session = session.token },
    })
  end
end

function M.invalidate(session, repo)
  repo = canonical(repo)
  session.sync_roots = session.sync_roots or {}
  session.sync_roots[repo] = true
  session.sync_pending = session.sync_pending or {}
  if session.sync_pending[repo] then
    return
  end
  session.sync_pending[repo] = true
  vim.schedule(function()
    session.sync_pending[repo] = nil
    if not session.deleted and not session.exited then
      M.reconcile(session, repo)
    end
  end)
end

function M.setup()
  local group = api.nvim_create_augroup("IgitSync", { clear = true })
  api.nvim_create_autocmd({ "BufReadPost", "BufWritePost", "BufFilePost" }, {
    group = group, callback = function(event) remember(event.buf) end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = group, callback = function(event) disk[event.buf] = nil end,
  })
end

return M
