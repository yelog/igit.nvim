local M = {}
local api = vim.api
local uv = vim.uv

local bom = "\239\187\191"
local separators = { unix = "\n", dos = "\r\n" }
local sequence = 0

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.ERROR, { title = "igit.nvim" })
end

local function fail(message)
  return nil, message
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

local function normalize_encoding(value)
  value = (value or ""):lower()
  if value == "" or value == "utf-8" or value == "utf8" then
    return "utf-8"
  end
  return value
end

local function absolute_path(path)
  if path:match("^/") or path:match("^%a:[/\\]") or path:match("^\\\\") then
    return vim.fs.normalize(path)
  end
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local function source_window(source, buffer)
  if source and source.win and api.nvim_win_is_valid(source.win)
      and api.nvim_win_get_buf(source.win) == buffer then
    return source.win
  end
  local window = vim.fn.bufwinid(buffer)
  if window ~= -1 and api.nvim_win_is_valid(window) then
    return window
  end
end

local function current_undo_sequence(buffer)
  local ok, tree = pcall(api.nvim_buf_call, buffer, function()
    return vim.fn.undotree()
  end)
  if not ok or type(tree) ~= "table" then
    return nil
  end
  return tree.seq_cur
end

local function buffer_state(buffer)
  if not api.nvim_buf_is_valid(buffer) or not api.nvim_buf_is_loaded(buffer) then
    return fail("The current buffer is unavailable")
  end
  if vim.bo[buffer].buftype ~= "" then
    return fail("The current buffer is not a working file")
  end
  local name = api.nvim_buf_get_name(buffer)
  if name == "" then
    return fail("The current buffer has no file name")
  end
  if vim.bo[buffer].binary then
    return fail("Current-file diff does not support binary buffers")
  end
  local encoding = normalize_encoding(vim.bo[buffer].fileencoding)
  if encoding ~= "utf-8" then
    return fail("Current-file diff requires a UTF-8 buffer; fileencoding is " .. encoding)
  end
  if normalize_encoding(vim.o.encoding) ~= "utf-8" then
    return fail("Current-file diff requires Neovim's encoding to be UTF-8")
  end
  local fileformat = vim.bo[buffer].fileformat
  if not separators[fileformat] then
    return fail("Current-file diff supports only LF or CRLF line endings")
  end
  return {
    name = name,
    path = absolute_path(name),
    buftype = vim.bo[buffer].buftype,
    changedtick = api.nvim_buf_get_changedtick(buffer),
    encoding = encoding,
    fileformat = fileformat,
    endofline = vim.bo[buffer].endofline,
    fixendofline = vim.bo[buffer].fixendofline,
    bomb = vim.bo[buffer].bomb,
    undo_sequence = current_undo_sequence(buffer),
  }
end

local function zero_byte_buffer(buffer, lines)
  if #lines ~= 1 or lines[1] ~= "" then
    return false
  end
  return api.nvim_buf_call(buffer, function()
    return vim.fn.wordcount().bytes == 0
  end)
end

local function encode_lines(lines, state, empty)
  local separator = separators[state.fileformat]
  local value = table.concat(lines, separator)
  if state.endofline and not empty then
    value = value .. separator
  end
  if state.bomb then
    value = bom .. value
  end
  return value
end

local function split(value, separator)
  local result, start = {}, 1
  while true do
    local first, last = value:find(separator, start, true)
    if not first then
      result[#result + 1] = value:sub(start)
      return result
    end
    result[#result + 1] = value:sub(start, first - 1)
    start = last + 1
  end
end

local function decode_snapshot(value, state)
  if value:find("\0", 1, true) then
    return fail("The diff snapshot contains binary data")
  end
  local has_bom = value:sub(1, 3) == bom
  local body = has_bom and value:sub(4) or value
  if not valid_utf8(body) then
    return fail("The diff snapshot is not valid UTF-8")
  end
  local separator = separators[state.fileformat]
  local lines = split(body, separator)
  local empty = body == ""
  local endofline = false
  if not empty and body:sub(-#separator) == separator then
    endofline = true
    lines[#lines] = nil
  end
  if #lines == 0 then
    lines = { "" }
  end
  for _, line in ipairs(lines) do
    if line:find("\n", 1, true) then
      return fail("The diff snapshot uses unsupported mixed line endings")
    end
  end
  local decoded = {
    lines = lines,
    fileformat = state.fileformat,
    endofline = endofline,
    bomb = has_bom,
    empty = empty,
  }
  if encode_lines(lines, decoded, empty) ~= value then
    return fail("The diff snapshot changed the line-ending form")
  end
  return decoded
end

local function read_file(path)
  local descriptor, open_error = uv.fs_open(path, "r", 384)
  if not descriptor then
    return fail(open_error)
  end
  local stat, stat_error = uv.fs_fstat(descriptor)
  if not stat then
    uv.fs_close(descriptor)
    return fail(stat_error)
  end
  local chunks, offset = {}, 0
  while offset < stat.size do
    local chunk, read_error = uv.fs_read(descriptor, math.min(65536, stat.size - offset), offset)
    if not chunk then
      uv.fs_close(descriptor)
      return fail(read_error)
    end
    if chunk == "" then
      break
    end
    chunks[#chunks + 1] = chunk
    offset = offset + #chunk
  end
  uv.fs_close(descriptor)
  if offset ~= stat.size then
    return fail("Could not read the complete diff snapshot")
  end
  return table.concat(chunks)
end

local function write_file(path, value)
  local descriptor, open_error = uv.fs_open(path, "wx", 384)
  if not descriptor then
    return fail(open_error)
  end
  local offset = 0
  while offset < #value do
    local written, write_error = uv.fs_write(descriptor, value:sub(offset + 1), offset)
    if not written or written == 0 then
      uv.fs_close(descriptor)
      return fail(write_error or "Could not write the diff snapshot")
    end
    offset = offset + written
  end
  local closed, close_error = uv.fs_close(descriptor)
  if not closed then
    return fail(close_error)
  end
  return true
end

local function cleanup(spec)
  if spec.snapshot then
    pcall(uv.fs_unlink, spec.snapshot)
  end
  if spec.directory then
    pcall(uv.fs_rmdir, spec.directory)
  end
end

local function snapshot_path()
  sequence = sequence + 1
  local directory = absolute_path(vim.fn.tempname() .. "-igit-diff")
  local made, directory_error = uv.fs_mkdir(directory, 448)
  if not made then
    return nil, nil, directory_error
  end
  local path = directory .. "/buffer"
  return directory, path
end

local function matches_source(buffer, state)
  if not api.nvim_buf_is_valid(buffer) or not api.nvim_buf_is_loaded(buffer) then
    return fail("the source buffer disappeared")
  end
  if vim.bo[buffer].buftype ~= state.buftype then
    return fail("the source buffer is no longer a working file")
  end
  if api.nvim_buf_get_name(buffer) ~= state.name then
    return fail("the source buffer name changed")
  end
  if api.nvim_buf_get_changedtick(buffer) ~= state.changedtick then
    return fail("the source buffer changed")
  end
  if normalize_encoding(vim.bo[buffer].fileencoding) ~= state.encoding then
    return fail("the source buffer encoding changed")
  end
  if vim.bo[buffer].fileformat ~= state.fileformat
      or vim.bo[buffer].endofline ~= state.endofline
      or vim.bo[buffer].fixendofline ~= state.fixendofline
      or vim.bo[buffer].bomb ~= state.bomb then
    return fail("the source buffer line endings changed")
  end
  if not vim.bo[buffer].modifiable then
    return fail("the source buffer is not modifiable")
  end
  return true
end

local function recovery_name(spec)
  local basename = vim.fs.basename(spec.path):gsub("[\r\n]", " ")
  if basename == "" then
    basename = "buffer"
  end
  return "igit://diff-recovery/" .. spec.id .. "/" .. basename
end

local function apply_metadata(buffer, metadata)
  vim.bo[buffer].fileformat = metadata.fileformat
  vim.bo[buffer].fixendofline = metadata.fixendofline
  vim.bo[buffer].endofline = metadata.endofline
  vim.bo[buffer].bomb = metadata.bomb
end

local function metadata_matches(buffer, metadata)
  return vim.bo[buffer].fileformat == metadata.fileformat
    and vim.bo[buffer].fixendofline == metadata.fixendofline
    and vim.bo[buffer].endofline == metadata.endofline
    and vim.bo[buffer].bomb == metadata.bomb
end

local function watch_undo_metadata(buffer, before_sequence, applied_sequence, original, imported)
  if not before_sequence or not applied_sequence or before_sequence == applied_sequence then
    return
  end
  local scheduled = false
  local detached = false
  local ok, attached = pcall(api.nvim_buf_attach, buffer, false, {
    on_lines = function()
      if detached then
        return true
      end
      if scheduled then
        return
      end
      scheduled = true
      vim.schedule(function()
        scheduled = false
        if detached or not api.nvim_buf_is_valid(buffer) or not api.nvim_buf_is_loaded(buffer) then
          return
        end
        local sequence = current_undo_sequence(buffer)
        local metadata
        if sequence == before_sequence then
          metadata = original
        elseif sequence == applied_sequence then
          metadata = imported
        else
          detached = true
          return
        end
        if not metadata_matches(buffer, metadata) then
          pcall(apply_metadata, buffer, metadata)
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

local function apply_snapshot(spec, decoded)
  local buffer = spec.buffer
  local before_sequence = spec.state.undo_sequence
  api.nvim_buf_set_lines(buffer, 0, -1, false, decoded.empty and {} or decoded.lines)
  local imported = {
    fileformat = decoded.fileformat,
    fixendofline = spec.state.fixendofline,
    endofline = decoded.endofline,
    bomb = decoded.bomb,
  }
  apply_metadata(buffer, imported)
  local applied_sequence = current_undo_sequence(buffer)
  watch_undo_metadata(buffer, before_sequence, applied_sequence, {
    fileformat = spec.state.fileformat,
    fixendofline = spec.state.fixendofline,
    endofline = spec.state.endofline,
    bomb = spec.state.bomb,
  }, imported)
end

local function preserve(spec, decoded, reason)
  local created, buffer = pcall(api.nvim_create_buf, true, false)
  if not created then
    return fail(buffer)
  end
  local ok, error_message = pcall(function()
    api.nvim_buf_set_name(buffer, recovery_name(spec))
    vim.bo[buffer].buftype = "nofile"
    vim.bo[buffer].bufhidden = "hide"
    vim.bo[buffer].swapfile = false
    vim.bo[buffer].undofile = false
    vim.bo[buffer].buflisted = true
    vim.bo[buffer].fileencoding = "utf-8"
    vim.bo[buffer].fileformat = decoded.fileformat
    vim.bo[buffer].endofline = decoded.endofline
    vim.bo[buffer].fixendofline = spec.state.fixendofline
    vim.bo[buffer].bomb = decoded.bomb
    api.nvim_buf_set_lines(buffer, 0, -1, false, decoded.empty and {} or decoded.lines)
    vim.bo[buffer].filetype = vim.filetype.match({ filename = spec.path }) or ""
    vim.b[buffer].igit_file_diff_recovery = { source = spec.path, reason = reason }
  end)
  if not ok then
    pcall(api.nvim_buf_delete, buffer, { force = true })
    return fail(error_message)
  end
  return buffer
end

local function finish(spec, mode)
  if spec.finished then
    return spec.finish_result
  end
  spec.finished = true
  local value, read_error = read_file(spec.snapshot)
  if not value then
    cleanup(spec)
    if mode == "apply" then
      notify("Could not read the diff snapshot: " .. tostring(read_error))
      spec.finish_result = "error"
    else
      spec.finish_result = "unchanged"
    end
    return spec.finish_result
  end
  if value == spec.original then
    cleanup(spec)
    spec.finish_result = "unchanged"
    return spec.finish_result
  end
  local decoded, decode_error = decode_snapshot(value, spec.state)
  if not decoded then
    if mode == "apply" or mode == "preserve" then
      notify("Could not import the changed diff snapshot: " .. tostring(decode_error)
        .. ". The snapshot was kept at " .. spec.snapshot .. ".")
    end
    spec.keep_snapshot = true
    spec.finish_result = "error"
    return spec.finish_result
  end
  if mode == "apply" then
    local matches, reason = matches_source(spec.buffer, spec.state)
    if matches then
      local ok, error_message = pcall(apply_snapshot, spec, decoded)
      if ok then
        cleanup(spec)
        spec.finish_result = "applied"
        return spec.finish_result
      end
      reason = "the source buffer could not be updated: " .. tostring(error_message)
    end
    local recovered, recovery_error = preserve(spec, decoded, reason)
    if recovered then
      cleanup(spec)
      notify("Could not apply diff changes because " .. reason
        .. "; restored content is in buffer " .. recovered .. ".")
      spec.finish_result = "recovered"
    else
      notify("Could not apply diff changes because " .. reason
        .. "; the snapshot was kept at " .. spec.snapshot .. ": " .. tostring(recovery_error))
      spec.keep_snapshot = true
      spec.finish_result = "error"
    end
    return spec.finish_result
  end
  if mode == "preserve" then
    local reason = "the diff viewer closed before its changes could be imported"
    local recovered, recovery_error = preserve(spec, decoded, reason)
    if recovered then
      cleanup(spec)
      notify("Diff changes were not applied because " .. reason
        .. "; restored content is in buffer " .. recovered .. ".")
      spec.finish_result = "recovered"
    else
      notify("Could not preserve diff changes; the snapshot was kept at " .. spec.snapshot
        .. ": " .. tostring(recovery_error))
      spec.keep_snapshot = true
      spec.finish_result = "error"
    end
    return spec.finish_result
  end
  cleanup(spec)
  spec.finish_result = "discarded"
  return spec.finish_result
end

---Capture the current buffer and cursor and create a private UTF-8 snapshot.
---@param source? {win?: integer, buf?: integer}
---@return table? spec
---@return string? error
function M.prepare(source)
  source = source or {}
  local buffer = source.buf
  if not buffer or not api.nvim_buf_is_valid(buffer) then
    return fail("The current buffer is unavailable")
  end
  local window = source_window(source, buffer)
  if not window then
    return fail("The current file has no visible window")
  end
  local state, state_error = buffer_state(buffer)
  if not state then
    return fail(state_error)
  end
  local lines = api.nvim_buf_get_lines(buffer, 0, -1, false)
  local line = math.max(1, math.min(#lines, api.nvim_win_get_cursor(window)[1]))
  local empty = zero_byte_buffer(buffer, lines)
  local original = encode_lines(lines, state, empty)
  if original:find("\0", 1, true) then
    return fail("Current-file diff does not support binary buffers")
  end
  local body = state.bomb and original:sub(4) or original
  if not valid_utf8(body) then
    return fail("Current-file diff requires valid UTF-8 buffer content")
  end
  local directory, path, directory_error = snapshot_path()
  if not directory then
    return fail("Could not create a private diff snapshot: " .. tostring(directory_error))
  end
  local written, write_error = write_file(path, original)
  if not written then
    pcall(uv.fs_unlink, path)
    pcall(uv.fs_rmdir, directory)
    return fail("Could not write the diff snapshot: " .. tostring(write_error))
  end
  local spec = {
    id = tostring(uv.hrtime()) .. "-" .. tostring(sequence),
    path = state.path,
    line = line,
    buffer = buffer,
    state = state,
    original = original,
    directory = directory,
    snapshot = path,
    env = { IGIT_DIFF_BUFFER = path },
  }
  function spec.finish(mode)
    return finish(spec, mode or "apply")
  end
  function spec.abort()
    return finish(spec, "abort")
  end
  return spec
end

return M
