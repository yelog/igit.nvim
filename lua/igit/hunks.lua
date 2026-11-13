local M = {}
local api = vim.api
local git = require("igit.git")
local git_status = require("igit.status")
local namespace = api.nvim_create_namespace("igit.hunks")
local states, watchers, writes = {}, {}, {}
local preview

M.defaults = {
  enabled = true,
  debounce = 150,
  signs = { add = "│", change = "│", delete = "_" },
  colors = { add = "#549159", change = "#375FAD", delete = "#868A91" },
  staged_signs = true,
  priority = 6,
  max_file_size = 1024 * 1024,
}
local config = vim.deepcopy(M.defaults)
local queue

local function valid(buf)
  return api.nvim_buf_is_valid(buf) and api.nvim_buf_is_loaded(buf)
    and vim.bo[buf].buftype == "" and api.nvim_buf_get_name(buf) ~= ""
end

local function changed(repo, buf)
  api.nvim_exec_autocmds("User", { pattern = "IgitChanged", modeline = false, data = { repo = repo, buf = buf } })
end

local function unwatch(buf)
  for directory, watcher in pairs(watchers) do
    watcher.buffers[buf] = nil
    if not next(watcher.buffers) then
      watcher.handle:stop()
      watcher.handle:close()
      watchers[directory] = nil
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
  if api.nvim_buf_is_valid(buf) then
    api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  end
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
    local started = handle:start(context.gitdir, {}, function(err, filename)
      if not err and (not filename or filename == "index" or filename == "HEAD" or filename == "packed-refs") then
        vim.schedule(function()
          if watchers[context.gitdir] == watcher then
            changed(context.repo)
          end
        end)
      end
    end)
    if not started then
      handle:close()
      return
    end
    watchers[context.gitdir] = watcher
  end
  watcher.buffers[buf] = true
end

local function content(text)
  if #text > config.max_file_size then
    return nil, "File exceeds the hunk size limit"
  end
  if text:find("\0", 1, true) then
    return nil, "Hunks are unavailable for binary files"
  end
  local dos = text:find("\r\n", 1, true) ~= nil and not text:gsub("\r\n", ""):find("\n", 1, true)
  local normalized = dos and text:gsub("\r\n", "\n") or text
  local lines = vim.split(normalized, "\n", { plain = true })
  local eol = normalized:sub(-1) == "\n"
  if eol or normalized == "" then
    table.remove(lines)
  end
  return { raw = text, text = normalized, lines = lines, eol = eol, dos = dos }
end

local function differences(before, after)
  local diff = vim.text and vim.text.diff or vim.diff
  local result = diff(before.text, after.text, { result_type = "indices", algorithm = "histogram" })
  local hunks = {}
  for _, item in ipairs(result) do
    local start = math.max(1, item[3])
    hunks[#hunks + 1] = {
      old_start = item[1], old_count = item[2],
      new_start = item[3], new_count = item[4],
      start = start, finish = math.max(start, item[3] + item[4] - 1),
      type = item[2] == 0 and "add" or (item[4] == 0 and "delete" or "change"),
    }
  end
  return hunks
end

local function summary(hunks)
  local result = { added = 0, changed = 0, removed = 0 }
  for _, hunk in ipairs(hunks or {}) do
    if hunk.type == "add" then
      result.added = result.added + hunk.new_count
    elseif hunk.type == "delete" then
      result.removed = result.removed + hunk.old_count
    else
      local paired = math.min(hunk.new_count, hunk.old_count)
      result.changed = result.changed + paired
      result.added = result.added + hunk.new_count - paired
      result.removed = result.removed + hunk.old_count - paired
    end
  end
  return result
end

local function buffer_position(line, hunks)
  local offset = 0
  for _, hunk in ipairs(hunks) do
    if hunk.old_count == 0 then
      if line <= hunk.old_start then
        break
      end
    elseif line < hunk.old_start then
      break
    elseif line < hunk.old_start + hunk.old_count then
      return math.max(1, hunk.new_start + math.min(line - hunk.old_start, math.max(0, hunk.new_count - 1)))
    end
    offset = offset + hunk.new_count - hunk.old_count
  end
  return math.max(1, line + offset)
end

local function render(buf, snapshot)
  api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  if not config.enabled then
    return
  end
  local count = api.nvim_buf_line_count(buf)
  local function signs(hunks, staged)
    for _, hunk in ipairs(hunks) do
      local first = math.min(count, hunk.start)
      local last = math.min(count, hunk.finish)
      for line = first, last do
        local kind = hunk.type
        if kind == "change" and not staged and line - first >= hunk.old_count then
          kind = "add"
        end
        local group = "IgitHunk" .. (staged and "Staged" or "") .. kind:sub(1, 1):upper() .. kind:sub(2)
        api.nvim_buf_set_extmark(buf, namespace, line - 1, 0, {
          sign_text = config.signs[kind],
          sign_hl_group = group,
          priority = config.priority + (staged and 0 or 1),
        })
      end
    end
  end
  if config.staged_signs then
    signs(snapshot.staged, true)
  end
  signs(snapshot.hunks, false)
end

local function read(context, snapshot, callback)
  local function blob(oid, done)
    if not oid then
      return done("")
    end
    git.run(context.repo, { "cat-file", "blob", oid }, {}, function(result)
      if result.code ~= 0 then
        return callback(git.error(result))
      end
      done(result.stdout)
    end)
  end
  git.run(context.repo, { "ls-files", "--stage", "-z", "--", context.path }, {}, function(result)
    if result.code ~= 0 then
      return callback(git.error(result))
    end
    local entries = vim.split(result.stdout, "\0", { plain = true, trimempty = true })
    if #entries > 1 then
      return callback("Resolve the file's index conflicts before using hunks")
    end
    if entries[1] then
      local mode, oid, stage, path = entries[1]:match("^(%d+) (%x+) (%d)\t(.*)$")
      if stage ~= "0" or path ~= context.path then
        return callback("The file has an unsupported index entry")
      end
      if mode ~= "100644" and mode ~= "100755" then
        return callback("Hunks require a regular file")
      end
      snapshot.mode, snapshot.oid = mode, oid
    end
    blob(snapshot.oid, function(index_text)
      local index, index_error = content(index_text)
      if not index then
        return callback(index_error)
      end
      snapshot.index = index
      git.run(context.repo, { "rev-parse", "--verify", "HEAD" }, {}, function(head_result)
        if head_result.code ~= 0 then
          return git.run(context.repo, { "symbolic-ref", "--quiet", "HEAD" }, {}, function(ref_result)
            if ref_result.code ~= 0 then
              return callback(git.error(head_result))
            end
            git.run(context.repo, { "show-ref", "--verify", "--quiet", vim.trim(ref_result.stdout) }, {}, function(ref)
              if ref.code ~= 1 then
                return callback(git.error(head_result))
              end
              snapshot.head = assert(content(""))
              callback(nil, snapshot)
            end)
          end)
        end
        snapshot.revision = vim.trim(head_result.stdout)
        git.run(context.repo, { "ls-tree", "-z", snapshot.revision, "--", context.path }, {}, function(tree_result)
          if tree_result.code ~= 0 then
            return callback(git.error(tree_result))
          end
          if tree_result.stdout ~= "" then
            local mode, kind, oid, path = tree_result.stdout:match("^(%d+) (%w+) (%x+)\t(.-)%z$")
            if kind ~= "blob" or path ~= context.path or (mode ~= "100644" and mode ~= "100755") then
              return callback("Hunks require a regular file in HEAD")
            end
            snapshot.head_oid, snapshot.head_mode = oid, mode
          end
          blob(snapshot.head_oid, function(head_text)
            local head, head_error = content(head_text)
            if not head then
              return callback(head_error)
            end
            snapshot.head = head
            callback(nil, snapshot)
          end)
        end)
      end)
    end)
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
  local state = states[buf] or { request = 0 }
  states[buf] = state
  if state.timer then
    state.timer:stop()
  end
  state.request = state.request + 1
  local request = state.request
  local name = api.nvim_buf_get_name(buf)
  local tick = api.nvim_buf_get_changedtick(buf)
  local text, text_error = content(git.text(buf))
  if not text then
    state.snapshot = nil
    api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
    git_status.publish(buf, nil, nil, false)
    if callback then
      callback(text_error)
    end
    return
  end
  local snapshot = { buffer = text, tick = tick, name = name }
  local function current()
    return states[buf] == state and state.request == request and valid(buf)
      and api.nvim_buf_get_name(buf) == name and api.nvim_buf_get_changedtick(buf) == tick
  end
  local function finish(err, result)
    if not current() then
      if callback then
        callback("The buffer changed while reading Git; retry the hunk action")
      end
      return
    end
    if err then
      state.snapshot = nil
      api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
      git_status.publish(buf, nil, nil, false)
    else
      snapshot = result
      snapshot.context = state.context
      snapshot.hunks = differences(snapshot.index, snapshot.buffer)
      snapshot.staged = differences(snapshot.head, snapshot.index)
      for _, hunk in ipairs(snapshot.staged) do
        hunk.start = buffer_position(math.max(1, hunk.new_start), snapshot.hunks)
        hunk.finish = buffer_position(math.max(1, hunk.new_start + hunk.new_count - 1), snapshot.hunks)
        hunk.finish = math.max(hunk.start, hunk.finish)
        hunk.staged = true
      end
      snapshot.summary = summary(snapshot.hunks)
      snapshot.staged_summary = summary(snapshot.staged)
      state.snapshot = snapshot
      render(buf, snapshot)
      git_status.publish(buf, snapshot.summary, snapshot.staged_summary, true, snapshot.tick)
    end
    if callback then
      callback(err, result)
    end
  end
  if state.context and state.name == name then
    read(state.context, snapshot, finish)
  else
    git.context(buf, function(err, context)
      if not current() then
        return finish("The buffer changed")
      end
      if err then
        return finish(err)
      end
      unwatch(buf)
      state.context, state.name = context, name
      watch(buf, context)
      read(context, snapshot, finish)
    end)
  end
end

queue = function(buf)
  if not config.enabled or not valid(buf) then
    return
  end
  local state = states[buf] or { request = 0 }
  states[buf] = state
  if state.busy then
    state.pending = true
    return
  end
  state.request = state.request + 1
  state.snapshot = nil
  if not state.timer then
    state.timer = vim.uv.new_timer()
  end
  state.timer:stop()
  state.timer:start(config.debounce, 0, vim.schedule_wrap(function()
    if states[buf] == state and valid(buf) then
      if state.busy then
        state.pending = true
        return
      end
      M.refresh(buf)
    end
  end))
end

local function selected(hunks, line)
  for _, hunk in ipairs(hunks) do
    if line >= hunk.start and line <= hunk.finish then
      return hunk
    end
  end
end

local function splice(base, source, hunk, reverse)
  local start = reverse and hunk.new_start or hunk.old_start
  local count = reverse and hunk.new_count or hunk.old_count
  local source_start = reverse and hunk.old_start or hunk.new_start
  local source_count = reverse and hunk.old_count or hunk.new_count
  local prefix = count == 0 and start or start - 1
  local lines = {}
  for index = 1, prefix do
    lines[#lines + 1] = base.lines[index]
  end
  for index = source_start, source_start + source_count - 1 do
    lines[#lines + 1] = source.lines[index]
  end
  for index = prefix + count + 1, #base.lines do
    lines[#lines + 1] = base.lines[index]
  end
  local eol = base.eol
  if prefix + count == #base.lines then
    eol = source.eol
  end
  if #lines == 0 then
    eol = false
  end
  local text = table.concat(lines, "\n") .. (eol and "\n" or "")
  return text, lines, eol
end

local function normalize_range(range, line_count)
  if range == nil then
    return nil
  end
  if type(range) ~= "table" then
    return nil, "The hunk range must be a table"
  end
  local first = range[1] or range.start or range.line1
  local last = range[2] or range.finish or range.end_line or range.line2
  if type(first) ~= "number" or first % 1 ~= 0
      or type(last) ~= "number" or last % 1 ~= 0 then
    return nil, "The hunk range requires integer start and finish lines"
  end
  if first > last then
    first, last = last, first
  end
  first, last = math.max(1, first), math.min(line_count, last)
  if first > last then
    return nil, "The hunk range is outside the buffer"
  end
  return { first, last }
end

local function partial_hunk(hunk, first, last)
  if hunk.new_count == 0 then
    return nil
  end
  local start = math.max(first, hunk.new_start)
  local finish = math.min(last, hunk.new_start + hunk.new_count - 1)
  if start > finish then
    return nil
  end
  local old_start, old_count
  local full = start == hunk.new_start and finish == hunk.new_start + hunk.new_count - 1
  if full then
    old_start, old_count = hunk.old_start, hunk.old_count
  else
    local paired = math.min(hunk.old_count, hunk.new_count)
    local offset = start - hunk.new_start
    if offset >= paired then
      old_count = 0
      old_start = hunk.old_count == 0 and hunk.old_start or hunk.old_start + paired - 1
    else
      old_start = hunk.old_start + offset
      old_count = math.min(finish - hunk.new_start, paired - 1) - offset + 1
    end
  end
  return {
    old_start = old_start,
    old_count = old_count,
    new_start = start,
    new_count = finish - start + 1,
  }
end

local function apply_selection(base, source, hunks, range)
  local lines = vim.list_extend({}, base.lines)
  local shift, touched, eol = 0, false, base.eol
  for _, hunk in ipairs(hunks or {}) do
    local part = partial_hunk(hunk, range[1], range[2])
    if part then
      local prefix = (part.old_count == 0 and part.old_start or part.old_start - 1) + shift
      local replacement = vim.list_slice(source.lines, part.new_start, part.new_start + part.new_count - 1)
      for _ = 1, part.old_count do
        table.remove(lines, prefix + 1)
      end
      for index, line in ipairs(replacement) do
        table.insert(lines, prefix + index, line)
      end
      shift = shift + #replacement - part.old_count
      touched = true
      local old_finish = part.old_count == 0 and part.old_start or part.old_start + part.old_count - 1
      if old_finish >= #base.lines and part.new_start + part.new_count - 1 >= #source.lines then
        eol = source.eol
      end
    end
  end
  if not touched then
    return nil, nil, nil, false
  end
  if #lines == 0 then
    eol = false
  end
  return table.concat(lines, "\n") .. (eol and "\n" or ""), lines, eol, true
end

local function map_buffer_range(snapshot, range)
  local mapped = {}
  local index_position, buffer_position_value = 1, 1
  local function intersect(index_start, buffer_start, length)
    if length <= 0 then
      return
    end
    local first = math.max(range[1], buffer_start)
    local last = math.min(range[2], buffer_start + length - 1)
    if first <= last then
      local index_first = index_start + first - buffer_start
      mapped[#mapped + 1] = { index_first, index_first + last - first }
    end
  end
  for _, hunk in ipairs(snapshot.hunks) do
    local unchanged = hunk.old_count == 0 and hunk.old_start - index_position + 1
      or hunk.old_start - index_position
    if unchanged < 0 then
      return nil, "The unstaged hunks cannot be mapped to the index"
    end
    if unchanged > 0 then
      intersect(index_position, buffer_position_value, unchanged)
      index_position = index_position + unchanged
      buffer_position_value = buffer_position_value + unchanged
    end
    local paired = math.min(hunk.old_count, hunk.new_count)
    if paired > 0 then
      intersect(hunk.old_start, hunk.new_start, paired)
    end
    index_position = hunk.old_count == 0 and hunk.old_start + 1 or hunk.old_start + hunk.old_count
    buffer_position_value = hunk.new_count == 0 and hunk.new_start + 1 or hunk.new_start + hunk.new_count
  end
  intersect(index_position, buffer_position_value, #snapshot.index.lines - index_position + 1)
  if #mapped == 0 then
    return nil
  end
  local first, last = mapped[1][1], mapped[1][2]
  for index = 2, #mapped do
    if mapped[index][1] > last + 1 then
      return nil, "The selection crosses unstaged deleted lines; select staged lines directly"
    end
    last = math.max(last, mapped[index][2])
  end
  return { first, last }
end

local function restore_selection(target, source, hunks, range)
  local lines = vim.list_extend({}, target.lines)
  local shift, touched, eol = 0, false, target.eol
  for _, hunk in ipairs(hunks or {}) do
    local part = partial_hunk(hunk, range[1], range[2])
    if part then
      local first = part.new_start + shift
      local replacement = {}
      for index = part.old_start, part.old_start + part.old_count - 1 do
        replacement[#replacement + 1] = source.lines[index]
      end
      for _ = 1, part.new_count do
        table.remove(lines, first)
      end
      for index, line in ipairs(replacement) do
        table.insert(lines, first + index - 1, line)
      end
      shift = shift + part.old_count - part.new_count
      touched = true
      local old_finish = part.old_count == 0 and part.old_start or part.old_start + part.old_count - 1
      if part.new_start + part.new_count - 1 >= #target.lines
          and old_finish >= #source.lines then
        eol = source.eol
      end
    end
  end
  if not touched then
    return nil, nil, nil, false
  end
  if #lines == 0 then
    eol = false
  end
  return table.concat(lines, "\n") .. (eol and "\n" or ""), lines, eol, true
end

local function current_undo_sequence(buf)
  local ok, tree = pcall(api.nvim_buf_call, buf, function()
    return vim.fn.undotree()
  end)
  if not ok or type(tree) ~= "table" then
    return nil
  end
  return tree.seq_cur
end

local function metadata(buf)
  return {
    bomb = vim.bo[buf].bomb,
    endofline = vim.bo[buf].endofline,
    fixendofline = vim.bo[buf].fixendofline,
  }
end

local function same_metadata(buf, expected)
  return vim.bo[buf].bomb == expected.bomb
    and vim.bo[buf].endofline == expected.endofline
    and vim.bo[buf].fixendofline == expected.fixendofline
end

local function restore_metadata(buf, expected)
  vim.bo[buf].bomb = expected.bomb
  vim.bo[buf].endofline = expected.endofline
  vim.bo[buf].fixendofline = expected.fixendofline
end

local function watch_undo_metadata(buf, before_sequence, applied_sequence, original, imported)
  if not before_sequence or not applied_sequence or before_sequence == applied_sequence then
    return
  end
  local scheduled, detached = false, false
  local ok, attached = pcall(api.nvim_buf_attach, buf, false, {
    on_lines = function()
      if detached or scheduled then
        return detached or nil
      end
      scheduled = true
      vim.schedule(function()
        scheduled = false
        if detached or not api.nvim_buf_is_valid(buf) or not api.nvim_buf_is_loaded(buf) then
          return
        end
        local sequence = current_undo_sequence(buf)
        local expected
        if sequence == before_sequence then
          expected = original
        elseif sequence == applied_sequence then
          expected = imported
        else
          detached = true
          return
        end
        if not same_metadata(buf, expected) then
          pcall(restore_metadata, buf, expected)
        end
      end)
    end,
    on_detach = function()
      detached = true
    end,
  })
  if not ok or not attached then
    return
  end
end

local function set_buffer_content(buf, lines, eol)
  local replacement = vim.list_extend({}, lines)
  local bom = replacement[1] and replacement[1]:sub(1, 3) == "\239\187\191" or false
  if bom then
    replacement[1] = replacement[1]:sub(4)
  end
  if #replacement == 0 then
    replacement = { "" }
  end
  local before_sequence = current_undo_sequence(buf)
  local original = metadata(buf)
  local imported = {
    bomb = bom,
    endofline = eol,
    fixendofline = eol and original.fixendofline or false,
  }
  api.nvim_buf_set_lines(buf, 0, -1, false, replacement)
  restore_metadata(buf, imported)
  watch_undo_metadata(buf, before_sequence, current_undo_sequence(buf), original, imported)
end

local function quote(path)
  return '"' .. path:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t") .. '"'
end

local function patch(snapshot, target, remove)
  local context = snapshot.context
  local old_path, new_path = quote("a/" .. context.path), quote("b/" .. context.path)
  local header = "diff --git " .. old_path .. " " .. new_path .. "\n"
  if not snapshot.oid then
    local stat = vim.uv.fs_stat(context.absolute)
    local executable = stat and bit.band(stat.mode, 73) ~= 0
    header = header .. "new file mode " .. (executable and "100755" or "100644") .. "\n"
  elseif remove then
    header = header .. "deleted file mode " .. snapshot.mode .. "\n"
    header = header .. "index " .. snapshot.oid .. ".." .. string.rep("0", #snapshot.oid) .. "\n"
  end
  header = header .. "--- " .. (snapshot.oid and old_path or "/dev/null")
    .. "\n+++ " .. (remove and "/dev/null" or new_path) .. "\n"
  if snapshot.index.dos then
    target = target:gsub("\n", "\r\n")
  end
  local diff = vim.text and vim.text.diff or vim.diff
  local unified = diff(snapshot.index.raw, target, {
    result_type = "unified", algorithm = "histogram",
    ctxlen = math.max(#snapshot.index.lines, #snapshot.buffer.lines, #snapshot.head.lines) + 1,
  })
  return header .. unified
end

local function attribute_error(result)
  if result.code ~= 0 then
    return git.error(result)
  end
  local fields = vim.split(result.stdout, "\0", { plain = true, trimempty = true })
  for index = 3, #fields, 3 do
    if fields[index] ~= "unspecified" and fields[index] ~= "unset" then
      return "Hunk actions do not support Git " .. fields[index - 1] .. " attributes"
    end
  end
end

local function visual_mode(mode)
  local kind = mode:sub(1, 1)
  return kind == "v" or kind == "V" or kind == "\22"
end

function M.selected_range()
  if not visual_mode(api.nvim_get_mode().mode) then
    return nil
  end
  return { vim.fn.line("v"), vim.fn.line(".") }
end

local function action(kind, requested_range, whole_file)
  local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
  if not valid(buf) then
    return git.notify("The current buffer is not a working file")
  end
  if vim.bo[buf].fileencoding ~= "" and vim.bo[buf].fileencoding ~= "utf-8" then
    return git.notify("Hunk actions require UTF-8 files")
  end
  local state = states[buf] or { request = 0 }
  states[buf] = state
  if state.busy then
    return git.notify("A hunk action is already running")
  end
  if state.timer then
    state.timer:stop()
  end
  state.busy = true
  local visual_range = M.selected_range()
  local range = requested_range or visual_range
  if visual_range then
    pcall(vim.cmd, "normal! \27")
  end
  local line = api.nvim_win_get_cursor(win)[1]
  local function done(err)
    state.busy = false
    if err then
      git.notify(err)
    end
    if states[buf] == state then
      queue(buf)
    end
  end
  M.refresh(buf, function(err, snapshot)
    if err then
      return done(err)
    end
    if range and not whole_file then
      local normalized, range_error = normalize_range(range, #snapshot.buffer.lines)
      if not normalized then
        return done(range_error)
      end
      range = normalized
    end
    if kind == "reset" then
      if not vim.bo[buf].modifiable or vim.bo[buf].readonly then
        return done("The buffer is read-only")
      end
      local context = snapshot.context
      return git.run(context.repo, { "check-attr", "-z", "filter", "working-tree-encoding", "ident", "--", context.path }, {}, function(attributes)
        local failure = attribute_error(attributes)
        if failure then
          return done(failure)
        end
        if states[buf] ~= state or not valid(buf) or api.nvim_buf_get_changedtick(buf) ~= snapshot.tick
            or api.nvim_buf_get_name(buf) ~= snapshot.name then
          return done("The buffer changed; retry the hunk action")
        end
        if not vim.bo[buf].modifiable or vim.bo[buf].readonly then
          return done("The buffer is read-only")
        end
        local lines, eol, touched
        if whole_file then
          lines = vim.list_extend({}, snapshot.index.lines)
          eol = snapshot.index.eol
          touched = true
        elseif range then
          local _, replacement, replacement_eol, changed_range = restore_selection(
            snapshot.buffer, snapshot.index, snapshot.hunks, range)
          lines, eol, touched = replacement, replacement_eol, changed_range
        else
          local hunk = selected(snapshot.hunks, line)
          if not hunk then
            return done("No unstaged hunk at the cursor")
          end
          if hunk.new_count > 0 then
            local _, replacement, replacement_eol, changed_range = restore_selection(
              snapshot.buffer, snapshot.index, snapshot.hunks, {
                math.max(1, hunk.start),
                math.min(#snapshot.buffer.lines, hunk.finish),
              })
            lines, eol, touched = replacement, replacement_eol, changed_range
          else
            lines = vim.list_extend({}, snapshot.buffer.lines)
            local prefix = hunk.new_start
            for index = hunk.old_start, hunk.old_start + hunk.old_count - 1 do
              table.insert(lines, prefix + index - hunk.old_start + 1, snapshot.index.lines[index])
            end
            eol = prefix >= #snapshot.buffer.lines and snapshot.index.eol or snapshot.buffer.eol
            touched = true
          end
        end
        if not touched then
          return done("The selected range contains no unstaged changes")
        end
        set_buffer_content(buf, lines, eol)
        done()
        changed(snapshot.context.repo, buf)
      end)
    end
    local context = snapshot.context
    if writes[context.repo] then
      return done("Another index action is running in this repository")
    end
    writes[context.repo] = true
    local function finish(message)
      writes[context.repo] = nil
      done(message)
      changed(context.repo, buf)
    end
    git.run(context.repo, { "check-attr", "-z", "filter", "working-tree-encoding", "ident", "--", context.path }, {}, function(attributes)
      local failure = attribute_error(attributes)
      if failure then
        return finish(failure)
      end
      if states[buf] ~= state or not valid(buf) or api.nvim_buf_get_changedtick(buf) ~= snapshot.tick
          or api.nvim_buf_get_name(buf) ~= snapshot.name then
        return finish("The buffer changed; retry the hunk action")
      end
      local stat = vim.uv.fs_lstat(context.absolute)
      if stat and stat.type ~= "file" then
        return finish("Hunk writes require a regular working file")
      end
      local target, touched
      if whole_file then
        if kind == "unstage" then
          if #snapshot.staged == 0 and not (snapshot.oid and not snapshot.head_oid) then
            return finish("No staged changes in this file")
          end
          target = snapshot.head.text
        elseif #snapshot.hunks == 0 and snapshot.oid then
          return finish("No unstaged changes in this file")
        else
          target = snapshot.buffer.text
        end
        touched = true
      elseif range then
        if kind == "unstage" then
          if #snapshot.staged == 0 then
            return finish("No staged changes in this file")
          end
          local mapped, map_error = map_buffer_range(snapshot, range)
          if not mapped then
            return finish(map_error or "The selected range contains no staged lines")
          end
          target, _, _, touched = restore_selection(snapshot.index, snapshot.head, snapshot.staged, mapped)
        else
          target, _, _, touched = apply_selection(snapshot.index, snapshot.buffer, snapshot.hunks, range)
        end
      else
        local hunk = selected(kind == "unstage" and snapshot.staged or snapshot.hunks, line)
        if not hunk then
          return finish("No " .. (kind == "unstage" and "staged" or "unstaged") .. " hunk at the cursor")
        end
        target = kind == "unstage" and splice(snapshot.index, snapshot.head, hunk, true)
          or splice(snapshot.index, snapshot.buffer, hunk, false)
        touched = true
      end
      if not touched then
        return finish("The selected range contains no " .. (kind == "unstage" and "staged" or "unstaged") .. " changes")
      end
      local registration_change = whole_file and kind == "unstage"
        and snapshot.oid and not snapshot.head_oid and #snapshot.staged == 0
      if target == snapshot.index.text
          and not (whole_file and kind == "stage" and not snapshot.oid)
          and not registration_change then
        return finish("The selected " .. (whole_file and "file has" or "range has")
          .. " no " .. (kind == "unstage" and "staged" or "unstaged") .. " changes")
      end
      local remove = kind == "unstage" and not snapshot.head_oid and target == ""
      git.run(context.repo, { "apply", "--cached", "--whitespace=nowarn", "-" }, {
        stdin = patch(snapshot, target, remove),
      }, function(result)
        finish(result.code ~= 0 and ("Could not " .. kind .. " " .. (whole_file and "file" or "hunk")
          .. ": " .. git.error(result)) or nil)
      end)
    end)
  end)
  return true
end

function M.stage_hunk(range)
  return action("stage", range)
end

function M.unstage_hunk(range)
  return action("unstage", range)
end

function M.reset_hunk(range)
  return action("reset", range)
end

function M.stage_file()
  return action("stage", nil, true)
end

function M.unstage_file()
  return action("unstage", nil, true)
end

function M.reset_file()
  return action("reset", nil, true)
end

function M.get_hunks(buf, staged)
  buf = buf and buf ~= 0 and buf or api.nvim_get_current_buf()
  local snapshot = states[buf] and states[buf].snapshot
  return snapshot and vim.deepcopy(staged and snapshot.staged or snapshot.hunks) or {}
end

local function ensure_snapshot(buf, state)
  local snapshot = state.snapshot
  if snapshot and snapshot.tick == api.nvim_buf_get_changedtick(buf)
      and snapshot.name == api.nvim_buf_get_name(buf) then
    return snapshot
  end
  local finished, failure = false, nil
  M.refresh(buf, function(err)
    failure, finished = err, true
  end)
  if not finished then
    vim.wait(2000, function() return finished end, 10)
  end
  if not finished then
    return nil, "Timed out while preparing the Git hunk"
  end
  if failure then
    return nil, failure
  end
  return state.snapshot
end

function M.select_hunk()
  local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
  if not valid(buf) then
    return git.notify("The current buffer is not a working file")
  end
  local state = states[buf] or { request = 0 }
  states[buf] = state
  local snapshot, snapshot_error = ensure_snapshot(buf, state)
  if not snapshot then
    return git.notify(snapshot_error)
  end
  local line = api.nvim_win_get_cursor(win)[1]
  local hunk = snapshot and (selected(snapshot.hunks, line) or selected(snapshot.staged, line))
  if not hunk then
    return git.notify("No Git hunk at the cursor")
  end
  if hunk.new_count == 0 then
    return git.notify("Deletion-only hunks have no buffer text to select")
  end
  local first = math.max(1, hunk.start)
  local last = math.min(api.nvim_buf_line_count(buf), hunk.finish)
  if first > last then
    return git.notify("The Git hunk has no selectable buffer lines")
  end
  if visual_mode(api.nvim_get_mode().mode) then
    pcall(vim.cmd, "normal! \27")
  end
  pcall(vim.cmd, ("normal! %dGV%dG"):format(first, last))
  return true
end

local function close_preview()
  if not preview then
    return
  end
  local current = preview
  preview = nil
  if api.nvim_win_is_valid(current.win) then
    pcall(api.nvim_win_close, current.win, true)
  end
  if api.nvim_buf_is_valid(current.buf) then
    pcall(api.nvim_buf_delete, current.buf, { force = true })
  end
end

local function preview_text(snapshot, hunk, staged)
  local old = staged and snapshot.head or snapshot.index
  local new = staged and snapshot.index or snapshot.buffer
  local old_prefix = hunk.old_count == 0 and hunk.old_start or hunk.old_start - 1
  local new_prefix = hunk.new_count == 0 and hunk.new_start or hunk.new_start - 1
  local before = math.min(3, math.max(0, old_prefix), math.max(0, new_prefix))
  local old_end = old_prefix + hunk.old_count
  local new_end = new_prefix + hunk.new_count
  local after = math.min(3, math.max(0, #old.lines - old_end), math.max(0, #new.lines - new_end))
  local old_start = old_prefix - before + 1
  local new_start = new_prefix - before + 1
  local lines = {
    "diff --git a/" .. snapshot.context.path .. " b/" .. snapshot.context.path,
    "--- a/" .. snapshot.context.path,
    "+++ b/" .. snapshot.context.path,
    ("@@ -%d,%d +%d,%d @@"):format(old_start, before + hunk.old_count + after,
      new_start, before + hunk.new_count + after),
  }
  for index = old_prefix - before + 1, old_prefix do
    lines[#lines + 1] = " " .. old.lines[index]
  end
  for index = old_prefix + 1, old_prefix + hunk.old_count do
    lines[#lines + 1] = "-" .. old.lines[index]
  end
  for index = new_prefix + 1, new_prefix + hunk.new_count do
    lines[#lines + 1] = "+" .. new.lines[index]
  end
  for index = 1, after do
    lines[#lines + 1] = " " .. old.lines[old_end + index]
  end
  return lines
end

function M.preview_hunk()
  local buf = api.nvim_get_current_buf()
  if not valid(buf) then
    return git.notify("The current buffer is not a working file")
  end
  local state = states[buf] or { request = 0 }
  states[buf] = state
  if state.busy then
    return git.notify("A hunk action is already running")
  end
  local snapshot, snapshot_error = ensure_snapshot(buf, state)
  if not snapshot then
    return git.notify(snapshot_error)
  end
  local line = api.nvim_win_get_cursor(0)[1]
  local hunk = selected(snapshot.hunks, line) or selected(snapshot.staged, line)
  if not hunk then
    return git.notify("No Git hunk at the cursor")
  end
  local staged = selected(snapshot.hunks, line) == nil
  local lines = preview_text(snapshot, hunk, staged)
  close_preview()
  local preview_buf = api.nvim_create_buf(false, true)
  vim.bo[preview_buf].bufhidden = "wipe"
  vim.bo[preview_buf].filetype = "diff"
  vim.bo[preview_buf].modifiable = true
  api.nvim_buf_set_lines(preview_buf, 0, -1, false, lines)
  vim.bo[preview_buf].modifiable = false
  vim.bo[preview_buf].readonly = true
  local width = math.max(1, math.min(vim.o.columns - 4, 100))
  local height = math.max(1, math.min(#lines, vim.o.lines - 6))
  local ok, win = pcall(api.nvim_open_win, preview_buf, false, {
    relative = "cursor",
    row = 1,
    col = 1,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = staged and " IGit Staged Hunk " or " IGit Hunk ",
    title_pos = "center",
  })
  if not ok then
    pcall(api.nvim_buf_delete, preview_buf, { force = true })
    return git.notify("Could not open the hunk preview: " .. tostring(win))
  end
  preview = { win = win, buf = preview_buf }
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, close_preview, { buffer = preview_buf, desc = "Close hunk preview", nowait = true })
  end
  return win, preview_buf
end

function M.navigate(direction)
  local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
  local count = vim.v.count1
  local function move(snapshot)
    if not api.nvim_win_is_valid(win) or api.nvim_get_current_win() ~= win or api.nvim_win_get_buf(win) ~= buf then
      return
    end
    local positions, seen = {}, {}
    for _, hunks in ipairs({ snapshot.hunks, snapshot.staged }) do
      for _, hunk in ipairs(hunks) do
        local position = math.min(api.nvim_buf_line_count(buf), hunk.start)
        if not seen[position] then
          seen[position] = true
          positions[#positions + 1] = position
        end
      end
    end
    if #positions == 0 then
      return
    end
    table.sort(positions)
    local line = api.nvim_win_get_cursor(win)[1]
    for _ = 1, count do
      local next_line
      if direction > 0 then
        for _, position in ipairs(positions) do
          if position > line then
            next_line = position
            break
          end
        end
        line = next_line or positions[1]
      else
        for index = #positions, 1, -1 do
          if positions[index] < line then
            next_line = positions[index]
            break
          end
        end
        line = next_line or positions[#positions]
      end
    end
    api.nvim_win_set_cursor(win, { line, 0 })
    api.nvim_win_call(win, function()
      vim.cmd("normal! zv")
    end)
  end
  if not valid(buf) then
    return git.notify("The current buffer is not a working file")
  end
  local state = states[buf] or { request = 0 }
  states[buf] = state
  if state.busy then
    return git.notify("A hunk action is already running")
  end
  local snapshot = state.snapshot
  if snapshot and snapshot.tick == api.nvim_buf_get_changedtick(buf) and snapshot.name == api.nvim_buf_get_name(buf) then
    return move(snapshot)
  end
  state.busy = true
  M.refresh(buf, function(err, result)
    state.busy = false
    if err then
      git.notify(err)
    else
      move(result)
    end
    if state.pending then
      state.pending = nil
      queue(buf)
    end
  end)
end

local function highlights()
  for kind, color in pairs(config.colors) do
    local suffix = kind:sub(1, 1):upper() .. kind:sub(2)
    api.nvim_set_hl(0, "IgitHunk" .. suffix, { fg = color })
    api.nvim_set_hl(0, "IgitHunkStaged" .. suffix, { fg = color, italic = true })
  end
end

function M.setup(options)
  local candidate = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), options or {})
  assert(type(candidate.enabled) == "boolean", "igit.nvim: hunks.enabled must be a boolean")
  assert(type(candidate.staged_signs) == "boolean", "igit.nvim: hunks.staged_signs must be a boolean")
  assert(type(candidate.debounce) == "number" and candidate.debounce >= 0 and candidate.debounce % 1 == 0,
    "igit.nvim: hunks.debounce must be a nonnegative integer")
  assert(type(candidate.priority) == "number" and candidate.priority >= 0 and candidate.priority <= 65534 and candidate.priority % 1 == 0,
    "igit.nvim: hunks.priority must be an integer between 0 and 65534")
  assert(type(candidate.max_file_size) == "number" and candidate.max_file_size > 0 and candidate.max_file_size % 1 == 0,
    "igit.nvim: hunks.max_file_size must be a positive integer")
  for _, kind in ipairs({ "add", "change", "delete" }) do
    local sign = candidate.signs[kind]
    assert(type(sign) == "string" and not sign:find("[%c]") and vim.fn.strdisplaywidth(sign) >= 1
      and vim.fn.strdisplaywidth(sign) <= 2, "igit.nvim: hunk signs must occupy one or two cells")
    assert(type(candidate.colors[kind]) == "string" and candidate.colors[kind]:match("^#%x%x%x%x%x%x$"),
      "igit.nvim: hunk colors must use #RRGGBB")
  end
  if not candidate.enabled then
    for buf in pairs(states) do
      git_status.publish(buf, nil, nil, false)
    end
  end
  for buf in pairs(states) do
    detach(buf)
  end
  config = candidate
  highlights()
  local group = api.nvim_create_augroup("IgitHunks", { clear = true })
  api.nvim_create_autocmd("ColorScheme", { group = group, callback = highlights })
  api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufEnter", "BufWritePost", "BufFilePost", "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = group, callback = function(event) queue(event.buf) end,
  })
  api.nvim_create_autocmd({ "FocusGained", "ShellCmdPost" }, {
    group = group, callback = function()
      for buf in pairs(states) do
        queue(buf)
      end
    end,
  })
  api.nvim_create_autocmd("User", {
    group = group, pattern = "IgitChanged", callback = function(event)
      for buf, state in pairs(states) do
        if not event.data or not event.data.repo or not state.context or state.context.repo == event.data.repo then
          queue(buf)
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
      queue(buf)
    end
  end
end

return M
