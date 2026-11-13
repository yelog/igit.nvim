local M = {}
local api = vim.api

function M.error(result)
  local message = (result.stderr or ""):gsub("%s+$", "")
  return message:match("([^\n]+)") or ("Git exited with code " .. tostring(result.code))
end

function M.run(repo, arguments, options, callback)
  local argv = { "git", "--literal-pathspecs", "-C", repo }
  vim.list_extend(argv, arguments)
  local settings = vim.tbl_extend("force", {
    text = false,
    timeout = 15000,
    env = { GIT_OPTIONAL_LOCKS = "0", GIT_NO_LAZY_FETCH = "1" },
  }, options or {})
  local ok, process = pcall(vim.system, argv, settings, function(result)
    vim.schedule(function()
      callback(result)
    end)
  end)
  if not ok then
    vim.schedule(function()
      callback({ code = -1, stdout = "", stderr = tostring(process) })
    end)
    return
  end
  return process
end

function M.context(buf, callback)
  if buf == nil or buf == 0 then
    buf = api.nvim_get_current_buf()
  end
  local function fail(message)
    vim.schedule(function()
      callback(message)
    end)
  end
  if not api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
    return fail("The current buffer is not a working file")
  end
  local name = api.nvim_buf_get_name(buf)
  if name == "" then
    return fail("The current buffer has no file name")
  end
  local absolute = vim.fs.normalize(name)
  local directory = vim.fs.dirname(absolute)
  while directory and not vim.uv.fs_stat(directory) do
    local parent = vim.fs.dirname(directory)
    if parent == directory then
      break
    end
    directory = parent
  end
  M.run(directory or vim.fn.getcwd(), { "rev-parse", "--show-toplevel", "--absolute-git-dir" }, {}, function(result)
    if result.code ~= 0 then
      return callback("The file is not in a Git working tree")
    end
    local root, gitdir = result.stdout:match("^([^\n]+)\n([^\n]+)\n?$")
    if not root then
      return callback("Could not resolve the Git working tree")
    end
    root, gitdir = vim.fs.normalize((root:gsub("\r$", ""))), vim.fs.normalize((gitdir:gsub("\r$", "")))
    local real_directory = vim.uv.fs_realpath(vim.fs.dirname(absolute))
    if real_directory then
      absolute = vim.fs.normalize(real_directory .. "/" .. vim.fs.basename(absolute))
    end
    local real_root = vim.uv.fs_realpath(root)
    root = real_root and vim.fs.normalize(real_root) or root
    local prefix = root:sub(-1) == "/" and root or root .. "/"
    local path = absolute:sub(1, #prefix) == prefix and absolute:sub(#prefix + 1) or nil
    if not path or path == "" then
      return callback("The file is outside the Git working tree")
    end
    callback(nil, { repo = root, gitdir = gitdir, path = path, absolute = absolute })
  end)
end

function M.text(buf)
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local text = table.concat(lines, "\n")
  if vim.bo[buf].endofline then
    text = text .. "\n"
  end
  if #lines == 1 and lines[1] == "" then
    local bytes = api.nvim_buf_call(buf, function()
      return vim.fn.wordcount().bytes
    end)
    if bytes == 0 then
      text = ""
    end
  end
  if vim.bo[buf].bomb and (vim.bo[buf].fileencoding == "" or vim.bo[buf].fileencoding == "utf-8") then
    text = "\239\187\191" .. text
  end
  return text
end

function M.notify(message)
  vim.notify(message, vim.log.levels.ERROR, { title = "igit.nvim" })
  return nil, message
end

return M
