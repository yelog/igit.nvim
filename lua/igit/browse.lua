local M = {}
local api = vim.api
local git = require("igit.git")

M.defaults = {
  remote = nil,
  open = nil,
  hosts = {},
}

local config = vim.deepcopy(M.defaults)
local providers = { github = true, gitlab = true, bitbucket = true }
local default_hosts = {
  ["github.com"] = "github",
  ["gitlab.com"] = "gitlab",
  ["bitbucket.org"] = "bitbucket",
}

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function has_control(value)
  return value:find("[%z\1-\31\127]") ~= nil
end

local function report(message)
  vim.notify(message, vim.log.levels.ERROR, { title = "igit.nvim" })
end

local function remote_name_ok(name)
  return type(name) == "string"
    and name ~= ""
    and name == trim(name)
    and not name:match("^%-")
    and not name:find("%s")
    and not has_control(name)
end

local function remote_override_ok(value)
  return type(value) == "string"
    and value ~= ""
    and value == trim(value)
    and not value:match("^%-")
    and not has_control(value)
end

local function validate_config(candidate)
  if candidate.remote ~= nil then
    assert(remote_override_ok(candidate.remote),
      "igit.browse: remote must be a non-empty remote name or URL without control characters")
  end
  if candidate.open ~= nil then
    assert(type(candidate.open) == "function", "igit.browse: open must be a function")
  end
  assert(type(candidate.hosts) == "table", "igit.browse: hosts must be a table")
  for host, provider in pairs(candidate.hosts) do
    assert(type(host) == "string" and host ~= "" and not host:find("[%s/\\@]") and not has_control(host),
      "igit.browse: host mappings must use non-empty hosts without paths or credentials")
    assert(providers[provider],
      "igit.browse: host '" .. host .. "' must map to github, gitlab, or bitbucket")
  end
end

---Configure current-file URL browsing.
---@param options? {remote?: string, open?: fun(url: string), hosts?: table<string, string>}
function M.setup(options)
  assert(options == nil or type(options) == "table", "igit.browse: setup options must be a table")
  local candidate = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), vim.deepcopy(options or {}))
  validate_config(candidate)
  config = candidate
end

local function cursor_line(buffer)
  local window = api.nvim_get_current_win()
  if api.nvim_win_get_buf(window) == buffer then
    return api.nvim_win_get_cursor(window)[1]
  end
  local other = vim.fn.bufwinid(buffer)
  if other ~= -1 and api.nvim_win_is_valid(other) then
    return api.nvim_win_get_cursor(other)[1]
  end
  return 1
end

local function prepare(options)
  if options == nil then
    options = {}
  elseif type(options) ~= "table" then
    return nil, "igit.browse: options must be a table"
  end

  local buf = options.buf
  if buf == nil or buf == 0 then
    buf = api.nvim_get_current_buf()
  elseif type(buf) ~= "number" or buf < 1 or buf % 1 ~= 0 or not api.nvim_buf_is_valid(buf) then
    return nil, "igit.browse: buf must be a valid buffer number"
  end

  if options.remote ~= nil and not remote_override_ok(options.remote) then
    return nil, "igit.browse: remote must be a non-empty remote name or URL without control characters"
  end

  local line, end_line = options.line, options.end_line
  for name, value in pairs({ line = line, end_line = end_line }) do
    if value ~= nil and (type(value) ~= "number" or value < 1 or value % 1 ~= 0) then
      return nil, "igit.browse: " .. name .. " must be a positive integer"
    end
  end

  line = line or cursor_line(buf)
  end_line = end_line or line
  if end_line < line then
    line, end_line = end_line, line
  end

  local file_buffer = vim.bo[buf].buftype == "" and api.nvim_buf_get_name(buf) ~= ""
  if not file_buffer then
    return nil, "igit.browse: the current buffer is not a named working file"
  end

  return {
    buf = buf,
    remote = options.remote,
    line = line,
    end_line = end_line,
    settings = vim.deepcopy(config),
  }
end

local function git_run(repo, args, callback)
  local ok, err = pcall(git.run, repo, args, {}, function(result)
    callback(result)
  end)
  if not ok then
    vim.schedule(function()
      callback({ code = 1, stdout = "", stderr = tostring(err) })
    end)
  end
end

local function command_error(action, result)
  local detail = git.error(result)
  if detail == nil or detail == "" then
    detail = "Git exited with code " .. tostring(result.code)
  end
  return action .. ": " .. trim(detail)
end

local function decode_uri_path(value)
  local result, index = {}, 1
  while index <= #value do
    local escape = value:sub(index + 1, index + 2)
    if value:sub(index, index) == "%" and escape:match("^%x%x$") then
      result[#result + 1] = string.char(tonumber(escape, 16))
      index = index + 3
    else
      result[#result + 1] = value:sub(index, index)
      index = index + 1
    end
  end
  return table.concat(result)
end

local function safe_relative_path(path)
  if path == "" or has_control(path) or path:sub(1, 1) == "/" or path:sub(-1) == "/"
      or path:find("\\", 1, true) or path:find("//", 1, true) then
    return false
  end
  for component in path:gmatch("[^/]+") do
    if component == "." or component == ".." then
      return false
    end
  end
  return true
end

local function normalize_remote_path(path)
  path = path:gsub("^/+", ""):gsub("/+$", "")
  path = path:gsub("%.git$", "")
  if not safe_relative_path(path) then
    return nil
  end
  return path
end

local function valid_host(host)
  return host ~= ""
    and not host:find("[^%w%._-]")
    and host:sub(1, 1) ~= "."
    and host:sub(-1) ~= "."
    and not host:find("..", 1, true)
end

local function parse_authority(authority)
  authority = authority:gsub("^.*@", "")
  if authority == "" then
    return nil, "malformed remote authority"
  end

  local host, port = authority:match("^([^:]+):(%d+)$")
  if not host then
    if authority:find(":", 1, true) then
      return nil, "malformed remote authority"
    end
    host = authority
  end
  if not valid_host(host) then
    return nil, "malformed remote host"
  end
  if port then
    local number = tonumber(port)
    if number < 1 or number > 65535 or number % 1 ~= 0 then
      return nil, "malformed remote port"
    end
  end
  return host:lower(), port
end

local function parse_remote_url(value)
  if type(value) ~= "string" or value == "" or value ~= trim(value) or has_control(value) then
    return nil, "invalid remote URL"
  end
  if value:match("^%-") then
    return nil, "invalid remote URL"
  end
  if value:match("^%a[%w+.-]*::") then
    return nil, "ext remote URLs are not supported"
  end
  if value:match("^file:") then
    return nil, "file remote URLs are not supported"
  end
  if value:match("^[/\\]") or value:match("^%a:[/\\]") or value:match("^%.%.?[/\\]")
      or value:match("^~[/\\]?") or value:find("\\", 1, true) then
    return nil, "local remote paths are not supported"
  end

  local scheme, rest = value:match("^([%a][%w+.-]*)://(.*)$")
  if scheme then
    scheme = scheme:lower()
    if scheme ~= "ssh" and scheme ~= "https" and scheme ~= "http" then
      return nil, "unsupported remote URL scheme"
    end
    local slash = rest:find("/", 1, true)
    if not slash then
      return nil, "malformed remote URL"
    end
    local host, port = parse_authority(rest:sub(1, slash - 1))
    if not host then
      return nil, port
    end
    local path = decode_uri_path(rest:sub(slash + 1):gsub("[?#].*$", ""))
    path = normalize_remote_path(path)
    if not path then
      return nil, "malformed remote repository path"
    end
    local browser_scheme = scheme == "http" and "http" or "https"
    local browser_port = port
    if scheme == "ssh" then
      browser_port = nil
    end
    if (browser_scheme == "http" and tonumber(browser_port) == 80)
        or (browser_scheme == "https" and tonumber(browser_port) == 443) then
      browser_port = nil
    end
    return {
      scheme = browser_scheme,
      host = host,
      port = browser_port,
      path = path,
    }
  end

  local authority, path = value:match("^([^/:]+):(.+)$")
  if not authority then
    return nil, "unsupported remote URL"
  end
  authority = authority:gsub("^.*@", "")
  if not valid_host(authority) then
    return nil, "malformed remote host"
  end
  path = normalize_remote_path(path)
  if not path then
    return nil, "malformed remote repository path"
  end
  return {
    scheme = "https",
    host = authority:lower(),
    path = path,
  }
end

local function encode_component(value)
  return (value:gsub(".", function(char)
    if char:match("[A-Za-z0-9%-._~]") then
      return char
    end
    return string.format("%%%02X", char:byte())
  end))
end

local function encode_path(value)
  return (value:gsub("[^/]+", encode_component))
end

local function normalize_host_key(host)
  return (host:lower():gsub("%.$", ""))
end

local function provider_for(settings, host)
  local key = normalize_host_key(host)
  for configured, provider in pairs(settings.hosts) do
    if normalize_host_key(configured) == key then
      return provider
    end
  end
  return default_hosts[key]
end

local function build_url(provider, parsed, ref, path, line, end_line)
  local repository = encode_path(parsed.path)
  local encoded_ref = encode_component(ref)
  local encoded_path = encode_path(path)
  local authority = parsed.host .. (parsed.port and ":" .. parsed.port or "")
  local base = parsed.scheme .. "://" .. authority .. "/" .. repository

  if provider == "github" then
    local url = base .. "/blob/" .. encoded_ref .. "/" .. encoded_path
    url = url .. "?plain=1#L" .. line
    if end_line ~= line then
      url = url .. "-L" .. end_line
    end
    return url
  elseif provider == "gitlab" then
    local url = base .. "/-/blob/" .. encoded_ref .. "/" .. encoded_path
    url = url .. "?plain=1#L" .. line
    if end_line ~= line then
      url = url .. "-" .. end_line
    end
    return url
  elseif provider == "bitbucket" then
    local url = base .. "/src/" .. encoded_ref .. "/" .. encoded_path
    url = url .. "#lines-" .. line
    if end_line ~= line then
      url = url .. ":" .. end_line
    end
    return url
  end
  return nil, "unsupported Git hosting provider"
end

local function read_upstream(stdout)
  for line in stdout:gmatch("[^\r\n]+") do
    local separator = line:find("\0", 1, true)
    if separator then
      local remote = trim(line:sub(1, separator - 1))
      local remote_ref = line:sub(separator + 1)
      remote_ref = trim(remote_ref)
      if remote ~= "" and remote ~= "." and remote_ref:sub(1, 11) == "refs/heads/" then
        return remote, remote_ref:sub(12)
      end
    end
  end
end

local function read_revision(repo, callback)
  git_run(repo, { "symbolic-ref", "--quiet", "--short", "HEAD" }, function(result)
    if result.code == 0 then
      local branch = trim(result.stdout)
      if branch == "" then
        callback("igit.browse: could not determine the current branch")
        return
      end
      local format = "%(upstream:remotename)%00%(upstream:remoteref)"
      git_run(repo, { "for-each-ref", "--format=" .. format, "refs/heads/" .. branch }, function(upstream)
        local remote, remote_ref
        if upstream.code == 0 then
          remote, remote_ref = read_upstream(upstream.stdout)
        end
        callback(nil, {
          branch = branch,
          upstream_remote = remote,
          upstream_ref = remote_ref,
        })
      end)
    else
      git_run(repo, { "rev-parse", "--verify", "HEAD" }, function(head)
        if head.code ~= 0 then
          callback(command_error("igit.browse: could not resolve HEAD", head))
          return
        end
        local sha = trim(head.stdout)
        if not sha:match("^[0-9a-fA-F]+$") then
          callback("igit.browse: Git returned an invalid HEAD revision")
          return
        end
        callback(nil, { detached = true, sha = sha })
      end)
    end
  end)
end

local function resolve_context(request, callback)
  local ok, err = pcall(git.context, request.buf, function(context_error, context)
    if context_error then
      callback("igit.browse: " .. tostring(context_error))
      return
    end
    if type(context) ~= "table" or type(context.repo) ~= "string" or context.repo == "" then
      callback("igit.browse: Git did not return a repository context")
      return
    end
    callback(nil, context)
  end)
  if not ok then
    callback("igit.browse: could not read Git context: " .. tostring(err))
  end
end

local function looks_like_remote(value)
  return value:find("://", 1, true) ~= nil
    or value:match("^[^/]+@[^/]+:") ~= nil
    or value:match("^[^/]+:") ~= nil
    or value:match("^[/\\]") ~= nil
    or value:match("^%a:[/\\]") ~= nil
    or value:match("^%.%.?[/\\]") ~= nil
    or value:match("^~[/\\]?") ~= nil
end

local function get_remote_url(repo, remote, callback)
  git_run(repo, { "remote", "get-url", "--", remote }, function(result)
    if result.code ~= 0 then
      callback(command_error("igit.browse: could not read remote '" .. remote .. "'", result))
      return
    end
    local url = trim(result.stdout)
    if url == "" then
      callback("igit.browse: remote '" .. remote .. "' has no URL")
      return
    end
    callback(nil, url, remote)
  end)
end

local function resolve_remote(request, revision, callback)
  local override = request.remote or request.settings.remote
  if override ~= nil then
    if looks_like_remote(override) then
      callback(nil, override)
      return
    end
    if not remote_name_ok(override) then
      callback("igit.browse: invalid remote name")
      return
    end
    get_remote_url(request.context.repo, override, callback)
    return
  end

  if revision.upstream_remote and revision.upstream_remote ~= "." then
    if not remote_name_ok(revision.upstream_remote) then
      callback("igit.browse: the current branch has an invalid upstream remote")
      return
    end
    get_remote_url(request.context.repo, revision.upstream_remote, callback)
    return
  end

  git_run(request.context.repo, { "remote" }, function(result)
    if result.code ~= 0 then
      callback(command_error("igit.browse: could not list Git remotes", result))
      return
    end
    local remotes = {}
    for line in result.stdout:gmatch("[^\r\n]+") do
      line = trim(line)
      if line ~= "" then
        remotes[#remotes + 1] = line
      end
    end
    if #remotes == 0 then
      callback("igit.browse: no Git remotes are configured")
      return
    end
    local selected
    for _, remote in ipairs(remotes) do
      if remote == "origin" then
        selected = remote
        break
      end
    end
    if not selected and #remotes == 1 then
      selected = remotes[1]
    end
    if not selected then
      callback("igit.browse: multiple Git remotes are configured; choose options.remote or configure browse.remote")
      return
    end
    get_remote_url(request.context.repo, selected, callback)
  end)
end

local function revision_ref(revision, remote)
  if revision.detached then
    return revision.sha
  end
  if remote and revision.upstream_remote == remote and revision.upstream_ref then
    return revision.upstream_ref
  end
  return revision.branch
end

local function context_path(context)
  if type(context.path) ~= "string" or context.path == "" then
    return nil
  end
  local path = context.path:gsub("\\", "/"):gsub("^%./", "")
  if not safe_relative_path(path) then
    return nil
  end
  return path
end

local function resolve(request, callback)
  resolve_context(request, function(context_error, context)
    if context_error then
      callback(context_error)
      return
    end
    request.context = context
    read_revision(context.repo, function(revision_error, revision)
      if revision_error then
        callback(revision_error)
        return
      end
      resolve_remote(request, revision, function(remote_error, remote_url, remote)
        if remote_error then
          callback(remote_error)
          return
        end
        local parsed, parse_error = parse_remote_url(remote_url)
        if not parsed then
          callback("igit.browse: unsupported Git remote URL (" .. parse_error .. ")")
          return
        end
        local provider = provider_for(request.settings, parsed.host)
        if not provider then
          callback("igit.browse: unsupported Git host '" .. parsed.host
            .. "'; configure browse.hosts['" .. parsed.host .. "'] with github, gitlab, or bitbucket")
          return
        end
        local ref = revision_ref(revision, remote)
        if type(ref) ~= "string" or not safe_relative_path(ref) then
          callback("igit.browse: could not determine a valid Git reference")
          return
        end
        local path = context_path(context)
        if not path then
          callback("igit.browse: could not determine the file path inside the repository")
          return
        end
        local url, build_error = build_url(provider, parsed, ref, path, request.line, request.end_line)
        if not url then
          callback("igit.browse: " .. build_error)
          return
        end
        callback(nil, url)
      end)
    end)
  end)
end

local function once(callback)
  local called = false
  return function(err, url)
    if called then
      return
    end
    called = true
    vim.schedule(function()
      callback(err, url)
    end)
  end
end

---Resolve a hosting URL without opening it.
---@param options? {buf?: integer, remote?: string, line?: integer, end_line?: integer}
---@param callback fun(error: string?, url: string?)
---@return nil, string?
function M.url(options, callback)
  if type(options) == "function" and callback == nil then
    options, callback = nil, options
  end
  if type(callback) ~= "function" then
    return nil, "igit.browse: callback must be a function"
  end
  local request, err = prepare(options)
  if not request then
    vim.schedule(function()
      callback(err)
    end)
    return nil, err
  end
  resolve(request, once(callback))
end

---Resolve and open the current file at the cursor line or an explicit range.
---@param options? {buf?: integer, remote?: string, line?: integer, end_line?: integer}
---@return true|nil, string?
function M.open(options)
  local request, err = prepare(options)
  if not request then
    report(err)
    return nil, err
  end

  local opener = request.settings.open or vim.ui.open
  resolve(request, once(function(resolve_error, url)
    if resolve_error then
      report(resolve_error)
      return
    end
    local ok, opened, open_error = pcall(opener, url)
    if not ok then
      report("igit.browse: could not open URL: " .. tostring(opened))
    elseif not opened and type(open_error) == "string" and open_error ~= "" then
      report("igit.browse: could not open URL: " .. open_error)
    end
  end))
  return true
end

return M
