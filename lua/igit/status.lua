local M = {}
local api = vim.api
local git = require("igit.git")

M.defaults = {
  enabled = true,
  debounce = 100,
}

local config = vim.deepcopy(M.defaults)
local states, watchers = {}, {}

local function valid(buf)
  return api.nvim_buf_is_valid(buf) and api.nvim_buf_is_loaded(buf)
    and vim.bo[buf].buftype == "" and api.nvim_buf_get_name(buf) ~= ""
end

local function zero()
  return { added = 0, changed = 0, removed = 0 }
end

local function counts()
  return { unstaged = zero(), staged = zero() }
end

local function copy_summary(value)
  value = value or zero()
  return {
    added = value.added or 0,
    changed = value.changed or 0,
    removed = value.removed or 0,
  }
end

local function same_summary(left, right)
  return left.added == right.added and left.changed == right.changed and left.removed == right.removed
end

local function view(state)
  if not state.base then
    return nil
  end
  local result = vim.deepcopy(state.base)
  result.unstaged = copy_summary(state.counts.unstaged)
  result.staged = copy_summary(state.counts.staged)
  result.added = result.unstaged.added
  result.changed = result.unstaged.changed
  result.removed = result.unstaged.removed
  local staged_total = result.staged.added + result.staged.changed + result.staged.removed
  local unstaged_total = result.unstaged.added + result.unstaged.changed + result.unstaged.removed
  local valid_buffer = valid(state.buffer)
  local counts_current = valid_buffer and state.counts_available
    and state.counts_tick == api.nvim_buf_get_changedtick(state.buffer)
  result.generation = state.generation
  if valid_buffer then
    result.buffer_modified = vim.bo[state.buffer].modified
  end
  local unsaved_changes = counts_current and unstaged_total > 0
    or (not counts_current and result.buffer_modified == true)
  if unsaved_changes and result.file_state == "clean" then
    result.file_state = "modified"
  end
  result.staged_changes = result.staged_changes or staged_total > 0
  result.unstaged_changes = result.unstaged_changes or unstaged_total > 0 or unsaved_changes
  result.modified = result.modified or unsaved_changes or unstaged_total > 0
  result.clean = result.clean and staged_total == 0 and unstaged_total == 0 and not unsaved_changes
  if result.clean then
    result.file_state = "clean"
  end
  return result
end

local function emit(buf, state)
  if not api.nvim_buf_is_valid(buf) then
    return
  end
  api.nvim_exec_autocmds("User", {
    pattern = "IgitUpdated",
    modeline = false,
    data = { buf = buf, status = view(state) },
  })
end

local function unwatch(buf)
  for gitdir, watcher in pairs(watchers) do
    watcher.buffers[buf] = nil
    if not next(watcher.buffers) then
      watcher.handle:stop()
      watcher.handle:close()
      watchers[gitdir] = nil
    end
  end
end

local function detach(buf)
  local state = states[buf]
  if state and state.timer then
    state.timer:stop()
    state.timer:close()
  end
  states[buf] = nil
  unwatch(buf)
end

local function watch(buf, context)
  if not config.enabled then
    return
  end
  local watcher = watchers[context.gitdir]
  if not watcher then
    local handle = vim.uv.new_fs_event()
    if not handle then
      return
    end
    watcher = { handle = handle, buffers = {} }
    local started = handle:start(context.gitdir, {}, function(err)
      if err then
        return
      end
      vim.schedule(function()
        if watchers[context.gitdir] ~= watcher then
          return
        end
        for watched in pairs(watcher.buffers) do
          M.queue(watched)
        end
      end)
    end)
    if not started then
      handle:close()
      return
    end
    watchers[context.gitdir] = watcher
  end
  watcher.buffers[buf] = true
end

local function set_base(buf, state, base)
  if state.base and base and vim.deep_equal(state.base, base) then
    return
  end
  if not state.base and not base then
    return
  end
  state.base = base
  state.generation = state.generation + 1
  emit(buf, state)
end

local function parse(output, context)
  local branch_oid, branch_head, upstream, ahead, behind
  local index_status, worktree_status
  local untracked, ignored, conflicted = false, false, false
  for line in (output .. "\n"):gmatch("(.-)\n") do
    local oid = line:match("^# branch%.oid (.+)$")
    local head = line:match("^# branch%.head (.+)$")
    if oid then
      branch_oid = oid
    elseif head then
      branch_head = head
    elseif line:match("^# branch%.upstream ") then
      upstream = line:match("^# branch%.upstream (.+)$")
    elseif line:match("^# branch%.ab ") then
      local add, remove = line:match("^# branch%.ab %+(%d+) %-(%d+)$")
      ahead, behind = tonumber(add), tonumber(remove)
    elseif line:sub(1, 2) == "1 " or line:sub(1, 2) == "2 " then
      local xy = line:sub(3, 4)
      if xy:match("^[%.MTADRCU][%.MTADRCU]$") then
        index_status, worktree_status = xy:sub(1, 1), xy:sub(2, 2)
      end
    elseif line:sub(1, 2) == "u " then
      local xy = line:sub(3, 4)
      if xy:match("^[%.MTADRCU][%.MTADRCU]$") then
        index_status, worktree_status, conflicted = xy:sub(1, 1), xy:sub(2, 2), true
      end
    elseif line:sub(1, 2) == "? " then
      untracked = true
    elseif line:sub(1, 2) == "! " then
      ignored = true
    end
  end
  index_status = index_status or "."
  worktree_status = worktree_status or "."
  local unborn = branch_oid == "(initial)"
  local detached = branch_head == "(detached)"
  local branch
  if detached then
    branch = branch_oid and branch_oid:sub(1, 8) or "HEAD"
  else
    branch = branch_head or "HEAD"
  end
  local clean = not untracked and not ignored and not conflicted
    and index_status == "." and worktree_status == "."
  local added = index_status == "A" or index_status == "C" or index_status == "R"
  local file_state
  if conflicted then
    file_state = "conflicted"
  elseif ignored then
    file_state = "ignored"
  elseif untracked or added then
    file_state = "added"
  elseif clean then
    file_state = "clean"
  else
    file_state = "modified"
  end
  return {
    repo = context.repo,
    root = context.repo,
    gitdir = context.gitdir,
    path = context.path,
    branch = branch,
    head = branch,
    oid = branch_oid ~= "(initial)" and branch_oid or nil,
    upstream = upstream,
    ahead = ahead,
    behind = behind,
    detached = detached,
    unborn = unborn,
    index_status = index_status,
    worktree_status = worktree_status,
    in_head = not unborn and not untracked and not ignored and not added,
    untracked = untracked,
    ignored = ignored,
    conflicted = conflicted,
    clean = clean,
    modified = not clean and not ignored,
    staged_changes = index_status ~= ".",
    unstaged_changes = worktree_status ~= ".",
    file_state = file_state,
  }
end

local function read(buf, state, context, request, name, callback)
  git.run(context.repo, {
    "status", "--porcelain=v2", "--branch", "--untracked-files=all",
    "--ignored=matching", "--", context.path,
  }, {}, function(result)
    if states[buf] ~= state or state.request ~= request or not valid(buf)
        or api.nvim_buf_get_name(buf) ~= name then
      if callback then
        callback("The buffer changed while reading Git status")
      end
      return
    end
    if result.code ~= 0 then
      state.context = nil
      state.counts = counts()
      state.counts_available, state.counts_tick = false, nil
      unwatch(buf)
      set_base(buf, state, nil)
      if callback then
        callback(nil, view(state))
      end
      return
    end
    set_base(buf, state, parse(result.stdout, context))
    if callback then
      callback(nil, view(state))
    end
  end)
end

function M.refresh(buf, callback)
  buf = buf and buf ~= 0 and buf or api.nvim_get_current_buf()
  if not valid(buf) then
    if callback then
      callback("The current buffer is not a working file")
    end
    return
  end
  local state = states[buf] or { buffer = buf, request = 0, generation = 0, counts = counts() }
  states[buf] = state
  state.buffer = buf
  if state.timer then
    state.timer:stop()
  end
  state.request = state.request + 1
  local request = state.request
  local name = api.nvim_buf_get_name(buf)
  local function current(context)
    if states[buf] ~= state or state.request ~= request or not valid(buf)
        or api.nvim_buf_get_name(buf) ~= name then
      if callback then
        callback("The buffer changed while reading Git status")
      end
      return
    end
    local previous = state.context
    if previous and (previous.repo ~= context.repo or previous.gitdir ~= context.gitdir
        or previous.path ~= context.path) then
      state.counts = counts()
      state.counts_available, state.counts_tick = false, nil
    end
    state.context = context
    watch(buf, context)
    read(buf, state, context, request, name, callback)
  end
  if state.context and state.name == name then
    read(buf, state, state.context, request, name, callback)
  else
    git.context(buf, function(err, context)
      if states[buf] ~= state or state.request ~= request or not valid(buf)
          or api.nvim_buf_get_name(buf) ~= name then
        if callback then
          callback("The buffer changed while reading Git status")
        end
        return
      end
      if err then
        state.context = nil
        state.name = nil
        state.counts = counts()
        state.counts_available, state.counts_tick = false, nil
        unwatch(buf)
        set_base(buf, state, nil)
        if callback then
          callback(err)
        end
        return
      end
      unwatch(buf)
      state.name = name
      current(context)
    end)
  end
end

function M.publish(buf, unstaged, staged, available, tick)
  if not config.enabled or not valid(buf) then
    return
  end
  local state = states[buf]
  if not state then
    state = { buffer = buf, request = 0, generation = 0, counts = counts() }
    states[buf] = state
  end
  local next_unstaged = unstaged and copy_summary(unstaged) or zero()
  local next_staged = staged and copy_summary(staged) or zero()
  available = available ~= false
  tick = tick or api.nvim_buf_get_changedtick(buf)
  if same_summary(state.counts.unstaged, next_unstaged)
      and same_summary(state.counts.staged, next_staged)
      and state.counts_available == available
      and state.counts_tick == tick then
    return
  end
  state.counts.unstaged, state.counts.staged = next_unstaged, next_staged
  state.counts_available, state.counts_tick = available, available and tick or nil
  state.generation = state.generation + 1
  if state.base then
    emit(buf, state)
  end
end

function M.get(buf)
  buf = buf and buf ~= 0 and buf or api.nvim_get_current_buf()
  local state = states[buf]
  return state and view(state) or nil
end

function M.queue(buf)
  if not config.enabled or not valid(buf) then
    return
  end
  local state = states[buf] or { buffer = buf, request = 0, generation = 0, counts = counts() }
  states[buf] = state
  state.buffer = buf
  if not state.timer then
    state.timer = vim.uv.new_timer()
  end
  state.timer:stop()
  state.timer:start(config.debounce, 0, vim.schedule_wrap(function()
    if states[buf] == state and valid(buf) then
      M.refresh(buf)
    end
  end))
end

function M.setup(options)
  local candidate = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), options or {})
  assert(type(candidate.enabled) == "boolean", "igit.nvim: status.enabled must be a boolean")
  assert(type(candidate.debounce) == "number" and candidate.debounce >= 0 and candidate.debounce % 1 == 0,
    "igit.nvim: status.debounce must be a nonnegative integer")
  for buf in pairs(states) do
    detach(buf)
  end
  config = candidate
  local group = api.nvim_create_augroup("IgitStatus", { clear = true })
  api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufEnter", "BufWritePost", "BufFilePost" }, {
    group = group, callback = function(event) M.queue(event.buf) end,
  })
  api.nvim_create_autocmd({ "FocusGained", "ShellCmdPost" }, {
    group = group, callback = function()
      for buf in pairs(states) do
        M.queue(buf)
      end
    end,
  })
  api.nvim_create_autocmd("User", {
    group = group, pattern = "IgitChanged", callback = function(event)
      for buf, state in pairs(states) do
        if not event.data or not event.data.repo or not state.context or state.context.repo == event.data.repo then
          M.queue(buf)
        end
      end
    end,
  })
  api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, { group = group, callback = function(event) detach(event.buf) end })
  api.nvim_create_autocmd("VimLeavePre", {
    group = group, callback = function()
      for buf in pairs(states) do
        detach(buf)
      end
    end,
  })
  if config.enabled then
    for _, buf in ipairs(api.nvim_list_bufs()) do
      M.queue(buf)
    end
  end
end

return M
