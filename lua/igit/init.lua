local M = {}
local api = vim.api

local defaults = {
  command = "igit",
  command_alias = true,
  window = { layout = "float", border = "rounded" },
  diff = { width = 0.95, height = 0.9 },
  hunks = {},
  status = {},
  blame = {},
  browse = {},
}
local config = vim.deepcopy(defaults)
local panels = { commit = true, log = true, push = true, branch = true, stash = true, diff = true }
local layouts = { float = true, left = true, right = true, bottom = true, tab = true }
local sessions, buffers = {}, {}
local active
local initialized = false
local editor_initialized = false

local function report(message)
  vim.notify(message, vim.log.levels.ERROR, { title = "igit.nvim" })
  return nil, message
end

local function validate_window(window)
  assert(type(window) == "table", "igit.nvim: window must be a table")
  assert(layouts[window.layout], "igit.nvim: window.layout must be float, left, right, bottom, or tab")
  for _, name in ipairs({ "width", "height" }) do
    local value = window[name]
    assert(value == nil or (type(value) == "number" and value > 0 and (value < 1 or value % 1 == 0)),
      "igit.nvim: window." .. name .. " must be a fraction between 0 and 1 or a positive cell count")
  end
  assert(type(window.border) == "string" or type(window.border) == "table", "igit.nvim: window.border must be a string or table")
end

local function validate_diff(diff, window)
  assert(type(diff) == "table", "igit.nvim: diff must be a table")
  local candidate = {
    layout = "float",
    width = diff.width,
    height = diff.height,
    border = diff.border or window.border,
  }
  local valid, validation_error = pcall(validate_window, candidate)
  assert(valid, (validation_error or "igit.nvim: invalid diff window"):gsub("window%.", "diff."))
end

local function command_argv(command)
  if type(command) == "function" then
    command = command()
  end
  if type(command) == "string" then
    command = { command }
  end
  assert(type(command) == "table" and #command > 0, "igit.nvim: command must be an executable or an argv list")
  local count = 0
  for key, value in pairs(command) do
    count = count + 1
    assert(type(key) == "number" and key >= 1 and key <= #command and key % 1 == 0 and type(value) == "string",
      "igit.nvim: command must be an argv list of strings")
  end
  assert(count == #command, "igit.nvim: command must not contain missing arguments")
  assert(command[1] ~= "", "igit.nvim: command executable must not be empty")
  return vim.deepcopy(command)
end

local function absolute_path(path, cwd)
  if path == "~" or path:sub(1, 2) == "~/" then
    path = vim.fn.expand("~") .. path:sub(2)
  end
  if not path:match("^/") and not path:match("^%a:[/\\]") and not path:match("^\\\\") then
    path = cwd .. "/" .. path
  end
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local function source_context()
  local win = api.nvim_get_current_win()
  local buf = api.nvim_get_current_buf()
  local session = buffers[buf]
  if session then
    return { win = session.source_win, buf = session.source_buf, cwd = session.cwd }
  end
  return { win = win, buf = buf, cwd = vim.fn.getcwd() }
end

local forget

local function retire(session)
  if session.deleted then
    return
  end
  local buffer, job = session.buf, session.job
  forget(session)
  if job then
    pcall(vim.fn.jobstop, job)
  end
  vim.schedule(function()
    if api.nvim_buf_is_valid(buffer) then
      pcall(api.nvim_buf_delete, buffer, { force = true })
    end
  end)
end

local function stop_current_job(session)
  local job = session.job
  if not job then
    return true
  end
  session.stopping_job = true
  pcall(vim.fn.jobstop, job)
  local waited, result = pcall(vim.fn.jobwait, { job }, 1000)
  session.stopping_job = false
  if not waited or type(result) ~= "table" then
    return false
  end
  local code = result[1]
  if session.exit_seen or code == -3 or (type(code) == "number" and code >= 0) then
    session.job = nil
    session.exited = true
    return true
  end
  return false
end

local function finish_hidden(session, mode)
  if session.hidden_notified then
    return true
  end
  if session.diff and session.job and not stop_current_job(session) then
    session.pending_finish = mode or "apply"
    return false
  end
  session.hidden_notified = true
  if session.diff then
    local ok, error_message = pcall(session.diff.finish, mode or "apply")
    if not ok then
      report("Could not import diff changes: " .. tostring(error_message))
    end
  end
  return true
end

local function hidden(session, mode)
  if finish_hidden(session, mode) and session.diff then
    retire(session)
  end
end

local function hide(session)
  if not session then
    return false
  end
  local win = session.win
  session.win = nil
  if active == session then
    active = nil
  end
  if not win or not api.nvim_win_is_valid(win) or api.nvim_win_get_buf(win) ~= session.buf then
    if session.diff then
      hidden(session)
    end
    return false
  end
  local focused = api.nvim_get_current_win() == win
  if focused then
    vim.cmd.stopinsert()
  end
  local closed = pcall(api.nvim_win_close, win, true)
  if not closed and api.nvim_win_is_valid(win) then
    -- A user may have closed every other window. Keep the terminal hidden
    -- without trying to close Neovim's last ordinary window.
    local replacement = session.source_buf
    if not replacement or not api.nvim_buf_is_valid(replacement) or replacement == session.buf then
      replacement = api.nvim_create_buf(true, false)
    end
    api.nvim_win_set_buf(win, replacement)
  end
  if focused and session.source_win and api.nvim_win_is_valid(session.source_win) then
    api.nvim_set_current_win(session.source_win)
  end
  hidden(session)
  return true
end

forget = function(session)
  if sessions[session.key] == session then
    sessions[session.key] = nil
  end
  buffers[session.buf] = nil
  if active == session then
    active = nil
  end
  session.deleted = true
end

local function dispose(session)
  hide(session)
  forget(session)
  if api.nvim_buf_is_valid(session.buf) then
    pcall(api.nvim_buf_delete, session.buf, { force = true })
  end
end

local function dimension(value, available, ratio)
  value = value or ratio
  return math.max(1, math.min(available, math.floor(value < 1 and available * value or value)))
end

local function float_config(window)
  local border = window.border
  local padding
  if border == "none" or border == "" then
    padding = 0
  else
    padding = 2
  end
  local columns = math.max(1, vim.o.columns - padding)
  local lines = math.max(1, vim.o.lines - vim.o.cmdheight - padding)
  local width = dimension(window.width, columns, 0.9)
  local height = dimension(window.height, lines, 0.85)
  return {
    relative = "editor",
    width = width,
    height = height,
    col = math.max(0, math.floor((vim.o.columns - width - padding) / 2)),
    row = math.max(0, math.floor((vim.o.lines - vim.o.cmdheight - height - padding) / 2)),
    style = "minimal",
    border = border,
    title = " IGit ",
    title_pos = "center",
  }
end

local function resize(session)
  if not session.win or not api.nvim_win_is_valid(session.win) then
    return
  end
  local window = session.window
  if window.layout == "float" then
    api.nvim_win_set_config(session.win, float_config(window))
  elseif window.layout == "left" or window.layout == "right" then
    api.nvim_win_set_width(session.win, dimension(window.width, math.max(1, vim.o.columns - 2), 0.5))
  elseif window.layout == "bottom" then
    api.nvim_win_set_height(session.win, dimension(window.height, math.max(1, vim.o.lines - vim.o.cmdheight - 2), 0.4))
  end
end

local function show(session, source, window)
  if session.win and api.nvim_win_is_valid(session.win) and api.nvim_win_get_buf(session.win) == session.buf
      and vim.deep_equal(session.window, window) then
    session.source_win = source.win
    session.source_buf = source.buf
    api.nvim_set_current_win(session.win)
    active = session
    if not session.exited then
      vim.cmd.startinsert()
    end
    return
  end
  hide(active)
  session.source_win = source.win
  session.source_buf = source.buf
  session.window = window
  if window.layout == "tab" then
    vim.cmd("tab split")
    session.win = api.nvim_get_current_win()
    api.nvim_win_set_buf(session.win, session.buf)
  elseif window.layout == "float" then
    session.win = api.nvim_open_win(session.buf, true, float_config(window))
  else
    session.win = api.nvim_open_win(session.buf, true, {
      split = window.layout == "bottom" and "below" or window.layout,
      win = -1,
    })
    resize(session)
  end
  active = session
  for name, value in pairs({ number = false, relativenumber = false, signcolumn = "no", foldcolumn = "0" }) do
    api.nvim_set_option_value(name, value, { win = session.win })
  end
  if not session.exited then
    vim.cmd.startinsert()
  end
end

local function initialize()
  if initialized then
    return
  end
  initialized = true
  local group = api.nvim_create_augroup("Igit", { clear = true })
  api.nvim_create_autocmd("TermRequest", {
    group = group,
    callback = function(event)
      require("igit.editor").request(event, buffers[event.buf], hide)
    end,
  })
  api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      if active then
        pcall(resize, active)
      end
    end,
  })
  api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(event)
      local win = tonumber(event.match)
      local closed
      for _, session in pairs(buffers) do
        if session.win == win then
          closed = session
          session.win = nil
          if active == session then
            active = nil
          end
          break
        end
      end
      if closed and closed.diff and not closed.hidden_notified then
        hidden(closed)
      end
    end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(event)
      local session = buffers[event.buf]
      if session then
        if session.diff then
          hidden(session, "preserve")
        else
          forget(session)
          if session.job then
            pcall(vim.fn.jobstop, session.job)
          end
        end
      end
    end,
  })
end

---Configure IGit. Existing terminal jobs keep running when configuration changes.
---@param options? table
function M.setup(options)
  assert(vim.fn.has("nvim-0.10") == 1, "igit.nvim requires Neovim 0.10 or newer")
  assert(options == nil or type(options) == "table", "igit.nvim: setup options must be a table")
  local candidate = vim.tbl_deep_extend("force", vim.deepcopy(defaults), options or {})
  if type(candidate.command) ~= "function" then
    command_argv(candidate.command)
  end
  validate_window(candidate.window)
  validate_diff(candidate.diff, candidate.window)
  assert(type(candidate.command_alias) == "boolean", "igit.nvim: command_alias must be a boolean")
  for _, name in ipairs({ "hunks", "status", "blame", "browse" }) do
    assert(type(candidate[name]) == "table", "igit.nvim: " .. name .. " must be a table")
  end
  require("igit.hunks").setup(candidate.hunks)
  require("igit.status").setup(candidate.status)
  require("igit.blame").setup(candidate.blame)
  require("igit.browse").setup(candidate.browse)
  editor_initialized = true
  config = candidate
  initialize()
  M._register_commands()
end

function M._register_commands()
  if not editor_initialized then
    require("igit.hunks").setup(config.hunks)
    require("igit.status").setup(config.status)
    require("igit.blame").setup(config.blame)
    require("igit.browse").setup(config.browse)
    editor_initialized = true
  end
  require("igit.command").register(config.command_alias)
end

function M.next_hunk()
  return require("igit.hunks").navigate(1)
end

function M.prev_hunk()
  return require("igit.hunks").navigate(-1)
end

function M.stage_hunk(range)
  return require("igit.hunks").stage_hunk(range)
end

function M.unstage_hunk(range)
  return require("igit.hunks").unstage_hunk(range)
end

function M.reset_hunk(range)
  return require("igit.hunks").reset_hunk(range)
end

function M.preview_hunk()
  return require("igit.hunks").preview_hunk()
end

function M.stage_file()
  return require("igit.hunks").stage_file()
end

function M.unstage_file()
  return require("igit.hunks").unstage_file()
end

function M.reset_file()
  return require("igit.hunks").reset_file()
end

function M.select_hunk()
  return require("igit.hunks").select_hunk()
end

---Return the cached Git status for a buffer without running Git.
---@param buf? integer
---@return table?
function M.status(buf)
  return require("igit.status").get(buf)
end

function M.file_blame()
  local result, err = require("igit.blame").file_blame()
  if err then
    return report(err)
  end
  return result
end

function M.toggle_inline_blame()
  local result, err = require("igit.blame").toggle_inline_blame()
  if err then
    return report(err)
  end
  return result
end

function M.blame_statusline(buf)
  return require("igit.blame").statusline(buf)
end

---Open the current file on its Git hosting provider at the cursor line.
---@param options? {buf?: integer, remote?: string, line?: integer, end_line?: integer}
function M.browse(options)
  return require("igit.browse").open(options)
end

---Open the current file's working-tree diff against HEAD in a floating viewer.
---@param options? {cwd?: string, window?: table}
---@return integer? buffer
---@return string? error
function M.file_diff(options)
  return M.open("diff", options)
end

---Open or focus an IGit terminal. Relative paths use the invoking window's cwd.
---@param panel? string
---@param options? {file?: string, cwd?: string, window?: table}
---@return integer? buffer
---@return string? error
function M.open(panel, options)
  if vim.fn.has("nvim-0.10") ~= 1 then
    return report("igit.nvim requires Neovim 0.10 or newer")
  end
  panel, options = panel or "commit", options or {}
  if not panels[panel] then
    return report("Unknown IGit panel: " .. tostring(panel))
  end
  if type(options) ~= "table" then
    return report("IGit options must be a table")
  end
  if options.file ~= nil and (panel ~= "log" or type(options.file) ~= "string" or options.file == "") then
    return report("A non-empty file path is supported only by the log panel")
  end
  if options.cwd ~= nil and (type(options.cwd) ~= "string" or options.cwd == "") then
    return report("IGit cwd must be a non-empty directory path")
  end
  if options.window ~= nil and type(options.window) ~= "table" then
    return report("IGit window options must be a table")
  end
  local window
  if panel == "diff" then
    window = vim.tbl_deep_extend("force", {
      layout = "float",
      width = config.diff.width,
      height = config.diff.height,
      border = config.diff.border or config.window.border,
    }, options.window or {}, { layout = "float" })
  else
    window = vim.tbl_deep_extend("force", vim.deepcopy(config.window), options.window or {})
  end
  local valid, validation_error = pcall(validate_window, window)
  if not valid then
    return report(validation_error)
  end
  local initial_source = source_context()
  local cwd = absolute_path(options.cwd or initial_source.cwd, initial_source.cwd)
  if vim.fn.isdirectory(cwd) ~= 1 then
    return report("IGit working directory does not exist: " .. cwd)
  end
  local resolved, argv = pcall(command_argv, config.command)
  if not resolved then
    return report("Could not resolve IGit command: " .. tostring(argv))
  end
  if argv[1]:find("[/\\]") then
    argv[1] = absolute_path(argv[1], initial_source.cwd)
  end
  if vim.fn.executable(argv[1]) ~= 1 then
    return report("IGit executable not found: " .. argv[1] .. ". Install IGit or set setup({ command = '/path/to/igit' }).")
  end
  if panel == "diff" and active and active.diff then
    hide(active)
  end
  local source = source_context()
  local file = options.file
  if file == "%" then
    if not source.buf or not api.nvim_buf_is_valid(source.buf) or vim.bo[source.buf].buftype ~= "" then
      return report("The originating buffer is not a file")
    end
    file = api.nvim_buf_get_name(source.buf)
    if file == "" then
      return report("The originating buffer has no file name")
    end
  end
  local diff
  table.insert(argv, panel)
  if panel == "diff" then
    diff, validation_error = require("igit.file_diff").prepare(source)
    if not diff then
      return report(validation_error)
    end
    table.insert(argv, "--line")
    table.insert(argv, tostring(diff.line))
    table.insert(argv, "--")
    table.insert(argv, diff.path)
  elseif file then
    table.insert(argv, "--")
    table.insert(argv, absolute_path(file, cwd))
  end
  initialize()
  local key_parts = { cwd, argv }
  if diff then
    key_parts[#key_parts + 1] = diff.id
  end
  local key = vim.json.encode(key_parts)
  local session = sessions[key]
  local created = not session
  if not session then
    local buf = api.nvim_create_buf(true, true)
    session = {
      key = key,
      buf = buf,
      cwd = cwd,
      token = tostring(buf) .. ":" .. tostring(vim.uv.hrtime()),
      panel = panel,
      diff = diff,
    }
    sessions[key], buffers[session.buf] = session, session
    vim.bo[session.buf].bufhidden = "hide"
    vim.bo[session.buf].swapfile = false
    vim.b[session.buf].igit = {
      panel = panel,
      cwd = cwd,
      argv = vim.deepcopy(argv),
      diff = diff and { path = diff.path, line = diff.line },
    }
  end
  local shown, show_error = pcall(show, session, source, window)
  if not shown then
    if diff then
      diff.abort()
    end
    if created then
      dispose(session)
    end
    return report("Could not open the IGit window: " .. tostring(show_error))
  end
  if not created then
    return session.buf
  end
  local env = { IGIT_NVIM_SESSION = session.token }
  if diff then
    for name, value in pairs(diff.env) do
      env[name] = value
    end
  end
  local started, job = pcall(vim.fn.termopen, argv, {
    cwd = cwd,
    env = env,
    on_exit = function(_, code)
      vim.schedule(function()
        if session.deleted then
          return
        end
        session.job = nil
        session.exited = true
        if session.stopping_job then
          session.exit_seen = true
          return
        end
        if session.pending_finish then
          local mode = session.pending_finish
          session.pending_finish = nil
          hidden(session, mode)
          return
        end
        if code == 0 then
          dispose(session)
        else
          if sessions[key] == session then
            sessions[key] = nil
          end
          if session.win and api.nvim_get_current_win() == session.win then
            vim.cmd.stopinsert()
          end
          report("IGit exited with code " .. code .. ". Terminal output is kept in buffer " .. session.buf .. ".")
        end
      end)
    end,
  })
  if not started or job <= 0 then
    if diff then
      diff.abort()
    end
    dispose(session)
    return report("Could not start IGit: " .. tostring(job))
  end
  session.job = job
  vim.bo[session.buf].filetype = "igit"
  vim.cmd.startinsert()
  return session.buf
end

---Hide the current IGit window. Current-file diff sessions are finalized first.
---@return boolean hidden
function M.close()
  local session = buffers[api.nvim_get_current_buf()] or active
  return hide(session)
end

return M
