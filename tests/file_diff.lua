local api = vim.api
local uv = vim.uv

vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.hidden = true
vim.o.columns = 140
vim.o.lines = 45
vim.cmd("runtime plugin/igit.lua")

local igit = require("igit")
local notices, passed = {}, 0
vim.notify = function(message, level, options)
  notices[#notices + 1] = {
    message = message,
    level = level,
    title = options and options.title,
  }
end

local temp = vim.fn.tempname() .. " igit file diff"
vim.fn.mkdir(temp, "p")
temp = assert(uv.fs_realpath(temp))
local repo = temp .. "/repo"
local record_path = temp .. "/record"
local fixture = temp .. "/fake igit.sh"
local file = repo .. "/file with 'quote' \"double\" $dollar #hash %percent [x] 中文.txt"
local crlf_file = repo .. "/crlf.txt"
local bom_file = repo .. "/bom.txt"
local empty_file = repo .. "/empty.txt"
local new_file = repo .. "/new-empty.txt"

local function run(arguments, text)
  local result = vim.system(arguments, { text = text ~= false }):wait()
  assert(result.code == 0, table.concat(arguments, " ") .. "\n" .. tostring(result.stderr))
  return result.stdout
end

local function git(...)
  local arguments = {
    "git", "-C", repo,
    "-c", "user.name=IGit Test",
    "-c", "user.email=igit@example.invalid",
    "-c", "commit.gpgsign=false",
  }
  vim.list_extend(arguments, { ... })
  return run(arguments)
end

local function write_bytes(path, value)
  local descriptor = assert(uv.fs_open(path, "w", 384))
  local written = 0
  while written < #value do
    local count = assert(uv.fs_write(descriptor, value:sub(written + 1), written))
    written = written + count
  end
  assert(uv.fs_close(descriptor))
end

local function read_bytes(path)
  local descriptor = assert(uv.fs_open(path, "r", 384))
  local stat = assert(uv.fs_fstat(descriptor))
  if stat.size == 0 then
    assert(uv.fs_close(descriptor))
    return ""
  end
  local value = assert(uv.fs_read(descriptor, stat.size, 0))
  assert(uv.fs_close(descriptor))
  return value
end

vim.fn.mkdir(repo, "p")
run({ "git", "-C", repo, "init", "-q", "-b", "main" })
git("config", "user.name", "IGit Test")
git("config", "user.email", "igit@example.invalid")
git("config", "commit.gpgsign", "false")
vim.fn.writefile({ "one", "two", "three", "four", "five" }, file)
write_bytes(crlf_file, "one\r\ntwo\r\nthree\r\n")
write_bytes(bom_file, "\239\187\191one\r\ntwo\r\nthree\r\n")
write_bytes(empty_file, "")
git("add", "--", file, crlf_file, bom_file, empty_file)
git("commit", "-qm", "initial")

vim.fn.writefile({
  "#!/bin/sh",
  'printf "%s\\n" "$PWD" > "$IGIT_DIFF_RECORD"',
  'printf "%s\\n" "$@" >> "$IGIT_DIFF_RECORD"',
  'printf "%s\\n" "$IGIT_DIFF_BUFFER" >> "$IGIT_DIFF_RECORD"',
  "while IFS= read -r line; do",
  '  case "$line" in',
  "    fail) exit 17 ;;",
  "    quit) exit 0 ;;",
  '    late) trap \'printf "late import\\n" > "$IGIT_DIFF_BUFFER"; exit 0\' TERM HUP; printf "late\\n" >> "$IGIT_DIFF_RECORD"; while IFS= read -r line; do :; done ;;',
  "  esac",
  "done",
}, fixture)
vim.fn.setfperm(fixture, "rwx------")
vim.env.IGIT_DIFF_RECORD = record_path
vim.cmd.cd(vim.fn.fnameescape(repo))

local source_win, source_buf
local terminal_buffer

local function equal(actual, expected, label)
  assert(vim.deep_equal(actual, expected),
    (label or "Values differ")
      .. "\nExpected: " .. vim.inspect(expected)
      .. "\nActual: " .. vim.inspect(actual))
end

local function contains(value, expected, label)
  assert(type(value) == "string" and value:find(expected, 1, true),
    (label or "Missing text") .. "\nExpected: " .. expected .. "\nActual: " .. tostring(value))
end

local function wait_for(condition, message)
  assert(vim.wait(5000, condition, 10), message or "Timed out")
end

local function clear_record()
  vim.fn.delete(record_path)
end

local function record()
  wait_for(function()
    return vim.fn.filereadable(record_path) == 1 and #vim.fn.readfile(record_path) >= 7
  end, "Fake diff executable did not start")
  return vim.fn.readfile(record_path)
end

local function reset_source(path)
  path = path or file
  if source_buf and api.nvim_buf_is_valid(source_buf) then
    vim.bo[source_buf].modified = false
  end
  vim.cmd("edit! " .. vim.fn.fnameescape(path))
  source_win = api.nvim_get_current_win()
  source_buf = api.nvim_get_current_buf()
  return source_buf
end

local function reset_lines(lines)
  api.nvim_buf_set_lines(source_buf, 0, -1, false, lines)
end

local function clean()
  igit.close()
  for _, buffer in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_valid(buffer) then
      local metadata = vim.b[buffer].igit_file_diff_recovery
      if vim.bo[buffer].filetype == "igit" or metadata then
        pcall(api.nvim_buf_delete, buffer, { force = true })
      end
    end
  end
  vim.wait(50, function()
    return false
  end)
  if source_win and api.nvim_win_is_valid(source_win) then
    api.nvim_set_current_win(source_win)
  end
  clear_record()
  notices = {}
  terminal_buffer = nil
end

local function recovery_buffer()
  for _, buffer in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_valid(buffer) and vim.b[buffer].igit_file_diff_recovery then
      return buffer
    end
  end
end

local function staged_changes()
  return git("diff", "--cached", "--name-only")
end

local function test(name, options, callback)
  if type(options) == "function" then
    callback, options = options, nil
  end
  clean()
  reset_source()
  local candidate = vim.tbl_deep_extend("force", {
    command = fixture,
    hunks = { enabled = false },
  }, options or {})
  igit.setup(candidate)
  local ok, err = xpcall(callback, debug.traceback)
  clean()
  if not ok then
    error(name .. "\n" .. tostring(err))
  end
  passed = passed + 1
  print("PASS " .. name)
end

local ok, err = xpcall(function()
  test("float diff uses current cursor, unsaved snapshot, literal argv, and private files", {
    window = { layout = "right" },
  }, function()
    reset_lines({ "one", "unsaved 二", "three", "four", "five" })
    api.nvim_win_set_cursor(source_win, { 2, 0 })
    terminal_buffer = assert(igit.file_diff())
    local values = record()
    equal(values[1], repo)
    equal(values[2], "diff")
    equal(values[3], "--line")
    equal(values[4], "2")
    equal(values[5], "--")
    equal(values[6], file)
    local snapshot = values[7]
    assert(snapshot:match("^/"))
    equal(read_bytes(snapshot), "one\nunsaved 二\nthree\nfour\nfive\n")
    local window = api.nvim_get_current_win()
    equal(api.nvim_win_get_config(window).relative, "editor")
    equal(api.nvim_get_current_buf(), terminal_buffer)
    local directory = vim.fs.dirname(snapshot)
    equal(assert(uv.fs_stat(directory)).mode % 512, 448)
    equal(assert(uv.fs_stat(snapshot)).mode % 512, 384)
    assert(igit.close())
    wait_for(function() return not api.nvim_buf_is_valid(terminal_buffer) end)
    assert(uv.fs_stat(snapshot) == nil)
    assert(uv.fs_stat(directory) == nil)
    equal(api.nvim_get_current_win(), source_win)
  end)

  test("hiding imports a changed snapshot as one undoable buffer change without writing", function()
    reset_lines({ "one", "unsaved edit", "three", "four", "five" })
    terminal_buffer = assert(igit.file_diff())
    local snapshot = record()[7]
    local disk = read_bytes(file)
    local staged = staged_changes()
    write_bytes(snapshot, "one\nrestored edit\nthree\nfour\nfive\n")
    assert(igit.close())
    equal(api.nvim_buf_get_lines(source_buf, 0, -1, false),
      { "one", "restored edit", "three", "four", "five" })
    equal(vim.bo[source_buf].modified, true)
    equal(read_bytes(file), disk)
    equal(staged_changes(), staged)
    vim.cmd("silent undo")
    equal(api.nvim_buf_get_lines(source_buf, 0, -1, false),
      { "one", "unsaved edit", "three", "four", "five" })
  end)

  test("hiding waits for the viewer before importing and removing its snapshot", function()
    reset_lines({ "one", "viewer active", "three", "four", "five" })
    terminal_buffer = assert(igit.file_diff())
    local snapshot = record()[7]
    local job = vim.b[terminal_buffer].terminal_job_id
    vim.fn.chansend(job, "late\n")
    wait_for(function()
      local values = vim.fn.readfile(record_path)
      return values[#values] == "late"
    end)
    assert(igit.close())
    equal(api.nvim_buf_get_lines(source_buf, 0, -1, false),
      { "late import" })
    assert(uv.fs_stat(snapshot) == nil)
    assert(uv.fs_stat(vim.fs.dirname(snapshot)) == nil)
  end)

  test("zero-byte empty buffers snapshot as empty instead of a newline", function()
    reset_source(empty_file)
    equal(api.nvim_buf_get_lines(source_buf, 0, -1, false), { "" })
    equal(vim.bo[source_buf].endofline, true)
    equal(api.nvim_buf_call(source_buf, function()
      return vim.fn.wordcount().bytes
    end), 0)
    terminal_buffer = assert(igit.file_diff())
    local snapshot = record()[7]
    equal(read_bytes(snapshot), "")
    assert(igit.close())
    wait_for(function() return not api.nvim_buf_is_valid(terminal_buffer) end)
    equal(api.nvim_buf_get_lines(source_buf, 0, -1, false), { "" })
    equal(vim.bo[source_buf].endofline, true)
    assert(uv.fs_stat(snapshot) == nil)
  end)

  test("new untracked content can restore to empty with undoable EOF metadata", function()
    pcall(uv.fs_unlink, new_file)
    reset_source(new_file)
    reset_lines({ "new one", "new two" })
    equal(vim.bo[source_buf].endofline, true)
    terminal_buffer = assert(igit.file_diff())
    local snapshot = record()[7]
    equal(read_bytes(snapshot), "new one\nnew two\n")
    write_bytes(snapshot, "")
    assert(igit.close())
    equal(api.nvim_buf_get_lines(source_buf, 0, -1, false), { "" })
    equal(vim.bo[source_buf].endofline, false)
    equal(vim.bo[source_buf].bomb, false)
    equal(api.nvim_buf_call(source_buf, function()
      return vim.fn.wordcount().bytes
    end), 0)
    equal(vim.bo[source_buf].modified, true)
    assert(uv.fs_stat(new_file) == nil)
    vim.cmd("silent undo")
    equal(api.nvim_buf_get_lines(source_buf, 0, -1, false), { "new one", "new two" })
    wait_for(function() return vim.bo[source_buf].endofline end)
    vim.cmd("silent redo")
    equal(api.nvim_buf_get_lines(source_buf, 0, -1, false), { "" })
    wait_for(function() return not vim.bo[source_buf].endofline end)
  end)

  test("a successful viewer exit imports changed content and cleans up", function()
    reset_lines({ "one", "exit wait", "three", "four", "five" })
    terminal_buffer = assert(igit.file_diff())
    local snapshot = record()[7]
    local job = vim.b[terminal_buffer].terminal_job_id
    local disk = read_bytes(file)
    write_bytes(snapshot, "one\nfrom exit\nthree\nfour\nfive\n")
    vim.fn.chansend(job, "quit\n")
    wait_for(function()
      return vim.deep_equal(api.nvim_buf_get_lines(source_buf, 0, -1, false),
        { "one", "from exit", "three", "four", "five" })
    end)
    wait_for(function() return not api.nvim_buf_is_valid(terminal_buffer) end)
    equal(read_bytes(file), disk)
    equal(staged_changes(), "")
    equal(notices, {})
    assert(uv.fs_stat(snapshot) == nil)
  end)

  test("reopening refreshes the cursor and snapshot instead of reusing the session", function()
    reset_lines({ "one", "unsaved", "three", "four", "five" })
    api.nvim_win_set_cursor(source_win, { 2, 0 })
    terminal_buffer = assert(igit.file_diff())
    local first = record()
    local first_terminal = terminal_buffer
    local first_snapshot = first[7]
    api.nvim_win_set_cursor(source_win, { 4, 0 })
    clear_record()
    terminal_buffer = assert(igit.file_diff())
    local second = record()
    equal(second[4], "4")
    equal(second[6], file)
    assert(second[7] ~= first_snapshot)
    equal(read_bytes(second[7]), "one\nunsaved\nthree\nfour\nfive\n")
    assert(uv.fs_stat(first_snapshot) == nil)
    wait_for(function() return not api.nvim_buf_is_valid(first_terminal) end)
    assert(terminal_buffer ~= first_terminal)
  end)

  test("stale source changes are preserved in a recovery buffer", function()
    reset_lines({ "one", "snapshot before", "three", "four", "five" })
    terminal_buffer = assert(igit.file_diff())
    local snapshot = record()[7]
    reset_lines({ "external edit" })
    write_bytes(snapshot, "native restored\n")
    assert(igit.close())
    equal(api.nvim_buf_get_lines(source_buf, 0, -1, false), { "external edit" })
    local recovery = assert(recovery_buffer())
    equal(api.nvim_buf_get_lines(recovery, 0, -1, false), { "native restored" })
    equal(vim.bo[recovery].buftype, "nofile")
    equal(vim.b[recovery].igit_file_diff_recovery.source, file)
    contains(vim.b[recovery].igit_file_diff_recovery.reason, "source buffer changed")
    assert(#notices >= 1)
    contains(notices[#notices].message, "restored content is in buffer")
    assert(uv.fs_stat(snapshot) == nil)
  end)

  test("renamed and line-ending-changed sources are not overwritten", function()
    reset_lines({ "one", "name guard", "three", "four", "five" })
    terminal_buffer = assert(igit.file_diff())
    local snapshot = record()[7]
    api.nvim_buf_set_name(source_buf, file .. ".renamed")
    write_bytes(snapshot, "renamed result\n")
    assert(igit.close())
    equal(api.nvim_buf_get_lines(source_buf, 0, -1, false),
      { "one", "name guard", "three", "four", "five" })
    local recovery = assert(recovery_buffer())
    equal(api.nvim_buf_get_lines(recovery, 0, -1, false), { "renamed result" })
    contains(vim.b[recovery].igit_file_diff_recovery.reason, "name changed")

    api.nvim_buf_delete(recovery, { force = true })
    clear_record()
    reset_source()
    reset_lines({ "one", "ending guard", "three", "four", "five" })
    terminal_buffer = assert(igit.file_diff())
    snapshot = record()[7]
    vim.bo[source_buf].fileformat = "dos"
    write_bytes(snapshot, "ending result\n")
    assert(igit.close())
    equal(api.nvim_buf_get_lines(source_buf, 0, -1, false),
      { "one", "ending guard", "three", "four", "five" })
    recovery = assert(recovery_buffer())
    equal(api.nvim_buf_get_lines(recovery, 0, -1, false), { "ending result" })
    contains(vim.b[recovery].igit_file_diff_recovery.reason, "line endings changed")
    vim.bo[source_buf].fileformat = "unix"
  end)

  test("non-UTF-8 buffers are rejected before launching", function()
    vim.bo[source_buf].fileencoding = "latin1"
    local buffer, message = igit.file_diff()
    equal(buffer, nil)
    contains(message, "UTF-8")
    equal(vim.fn.filereadable(record_path), 0)
    equal(api.nvim_get_current_win(), source_win)
    vim.bo[source_buf].fileencoding = "utf-8"
    reset_lines({ string.char(0xff) })
    buffer, message = igit.file_diff()
    equal(buffer, nil)
    contains(message, "valid UTF-8")
    equal(vim.fn.filereadable(record_path), 0)
    equal(api.nvim_get_current_win(), source_win)
    reset_lines({ "embedded\0NUL" })
    buffer, message = igit.file_diff()
    equal(buffer, nil)
    contains(message, "binary")
    equal(vim.fn.filereadable(record_path), 0)
    equal(api.nvim_get_current_win(), source_win)
  end)

  test("spawn failures clean up the private snapshot and restore focus", function()
    local original_termopen = vim.fn.termopen
    local snapshot
    vim.fn.termopen = function(_, options)
      snapshot = options.env.IGIT_DIFF_BUFFER
      return -1
    end
    local buffer, message = igit.file_diff()
    vim.fn.termopen = original_termopen
    equal(buffer, nil)
    contains(message, "Could not start IGit")
    assert(snapshot and snapshot:match("^/"))
    assert(uv.fs_stat(snapshot) == nil)
    assert(uv.fs_stat(vim.fs.dirname(snapshot)) == nil)
    equal(api.nvim_get_current_win(), source_win)
    equal(api.nvim_get_current_buf(), source_buf)
    equal(#notices, 1)
  end)

  test("CRLF snapshots and imports preserve file form", function()
    reset_source(crlf_file)
    equal(vim.bo[source_buf].fileformat, "dos")
    reset_lines({ "one", "crlf unsaved", "three" })
    terminal_buffer = assert(igit.file_diff())
    local snapshot = record()[7]
    equal(read_bytes(snapshot), "one\r\ncrlf unsaved\r\nthree\r\n")
    local disk = read_bytes(crlf_file)
    write_bytes(snapshot, "one\r\ncrlf restored\r\nthree\r\n")
    assert(igit.close())
    equal(vim.bo[source_buf].fileformat, "dos")
    equal(vim.bo[source_buf].endofline, true)
    equal(api.nvim_buf_get_lines(source_buf, 0, -1, false),
      { "one", "crlf restored", "three" })
    equal(read_bytes(crlf_file), disk)
    vim.cmd("silent undo")
    equal(api.nvim_buf_get_lines(source_buf, 0, -1, false),
      { "one", "crlf unsaved", "three" })
  end)

  test("UTF-8 BOM snapshots and imports preserve the BOM", function()
    reset_source(bom_file)
    equal(vim.bo[source_buf].bomb, true)
    reset_lines({ "one", "bom unsaved", "three" })
    terminal_buffer = assert(igit.file_diff())
    local snapshot = record()[7]
    equal(read_bytes(snapshot), "\239\187\191one\r\nbom unsaved\r\nthree\r\n")
    local disk = read_bytes(bom_file)
    write_bytes(snapshot, "\239\187\191one\r\nbom restored\r\nthree\r\n")
    assert(igit.close())
    equal(vim.bo[source_buf].bomb, true)
    equal(api.nvim_buf_get_lines(source_buf, 0, -1, false),
      { "one", "bom restored", "three" })
    equal(read_bytes(bom_file), disk)
    vim.cmd("silent undo")
    equal(api.nvim_buf_get_lines(source_buf, 0, -1, false),
      { "one", "bom unsaved", "three" })
  end)

  test("a first-hunk BOM difference is imported and restored by undo and redo", function()
    reset_source(bom_file)
    reset_lines({ "bom changed", "two", "three" })
    equal(vim.bo[source_buf].bomb, true)
    terminal_buffer = assert(igit.file_diff())
    local snapshot = record()[7]
    local disk = read_bytes(bom_file)
    write_bytes(snapshot, "bom restored\r\ntwo\r\nthree\r\n")
    assert(igit.close())
    equal(vim.bo[source_buf].fileformat, "dos")
    equal(vim.bo[source_buf].bomb, false)
    equal(vim.bo[source_buf].endofline, true)
    equal(api.nvim_buf_get_lines(source_buf, 0, -1, false),
      { "bom restored", "two", "three" })
    equal(read_bytes(bom_file), disk)
    vim.cmd("silent undo")
    equal(api.nvim_buf_get_lines(source_buf, 0, -1, false),
      { "bom changed", "two", "three" })
    wait_for(function() return vim.bo[source_buf].bomb end)
    vim.cmd("silent redo")
    equal(api.nvim_buf_get_lines(source_buf, 0, -1, false),
      { "bom restored", "two", "three" })
    wait_for(function() return not vim.bo[source_buf].bomb end)
  end)

  test("a final-hunk newline difference is imported and restored by undo and redo", function()
    reset_lines({ "one", "two", "three", "four", "eof unsaved" })
    equal(vim.bo[source_buf].endofline, true)
    terminal_buffer = assert(igit.file_diff())
    local snapshot = record()[7]
    local disk = read_bytes(file)
    write_bytes(snapshot, "one\ntwo\nthree\nfour\neof restored")
    assert(igit.close())
    equal(vim.bo[source_buf].endofline, false)
    equal(api.nvim_buf_get_lines(source_buf, 0, -1, false),
      { "one", "two", "three", "four", "eof restored" })
    equal(read_bytes(file), disk)
    vim.cmd("silent undo")
    equal(api.nvim_buf_get_lines(source_buf, 0, -1, false),
      { "one", "two", "three", "four", "eof unsaved" })
    wait_for(function() return vim.bo[source_buf].endofline end)
    vim.cmd("silent redo")
    equal(api.nvim_buf_get_lines(source_buf, 0, -1, false),
      { "one", "two", "three", "four", "eof restored" })
    wait_for(function() return not vim.bo[source_buf].endofline end)
  end)

  test("diff-specific float dimensions override split configuration and call options", {
    window = { layout = "right" },
    diff = { width = 80, height = 20, border = "single" },
  }, function()
    terminal_buffer = assert(igit.file_diff())
    local window = api.nvim_get_current_win()
    equal(api.nvim_win_get_config(window).relative, "editor")
    equal(api.nvim_win_get_width(window), 80)
    equal(api.nvim_win_get_height(window), 20)
    assert(igit.close())
    wait_for(function() return not api.nvim_buf_is_valid(terminal_buffer) end)
    clear_record()
    terminal_buffer = assert(igit.file_diff({ window = { layout = "bottom", width = 70, height = 12 } }))
    window = api.nvim_get_current_win()
    equal(api.nvim_win_get_config(window).relative, "editor")
    equal(api.nvim_win_get_width(window), 70)
    equal(api.nvim_win_get_height(window), 12)
  end)

  test("commands and Lua open('diff') use the current file", function()
    vim.cmd("Igit diff")
    terminal_buffer = api.nvim_get_current_buf()
    equal(record()[2], "diff")
    assert(igit.close())
    wait_for(function() return not api.nvim_buf_is_valid(terminal_buffer) end)
    clear_record()
    vim.cmd("IgitDiff")
    terminal_buffer = api.nvim_get_current_buf()
    equal(record()[6], file)
    assert(igit.close())
    wait_for(function() return not api.nvim_buf_is_valid(terminal_buffer) end)
    clear_record()
    terminal_buffer = assert(igit.open("diff"))
    equal(record()[2], "diff")
  end)
end, debug.traceback)

clean()
vim.fn.delete(temp, "rf")
if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
else
  print("Passed " .. passed .. " file diff tests")
  vim.cmd("qa!")
end
