-- Run from the repository root: nvim --headless -u NONE -l tests/run.lua
local api = vim.api
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.hidden = true
vim.o.lines = 45
vim.o.columns = 140
vim.cmd("runtime plugin/igit.lua")

local igit = require("igit")
local command = require("igit.command")
local temp = vim.fn.tempname() .. " igit 中文"
vim.fn.mkdir(temp, "p")
temp = assert(vim.uv.fs_realpath(temp))
local fixture = temp .. "/fake igit.sh"
vim.fn.writefile({
  '#!/bin/sh',
  'printf "%s\\n" "$PWD" "$@" > "$IGIT_NVIM_RECORD"',
  'printf "IGit test ready\\n"',
  'IFS= read -r reply',
  'if [ "$reply" = "fail" ]; then exit 23; fi',
  'exit 0',
}, fixture)
vim.fn.setfperm(fixture, "rwx------")
vim.env.IGIT_NVIM_RECORD = temp .. "/record"
local file = temp .. "/file with 空格 ; $dollar.txt"
vim.fn.writefile({ "test" }, file)
vim.cmd.edit(vim.fn.fnameescape(file))
vim.cmd.lcd(vim.fn.fnameescape(temp))
local origin = api.nvim_get_current_win()
local origin_buf = api.nvim_get_current_buf()
local notices = {}
vim.notify = function(message, level)
  notices[#notices + 1] = { message = message, level = level }
end

local passed = 0
local function equal(actual, expected, label)
  assert(vim.deep_equal(actual, expected), (label or "Values differ") .. "\nExpected: " .. vim.inspect(expected) .. "\nActual: " .. vim.inspect(actual))
end

local function wait_for(condition, message)
  assert(vim.wait(3000, condition, 10), message or "Timed out")
end

local function record()
  wait_for(function()
    return vim.fn.filereadable(vim.env.IGIT_NVIM_RECORD) == 1
  end, "Fake executable did not start")
  return vim.fn.readfile(vim.env.IGIT_NVIM_RECORD)
end

local function clear_record()
  vim.fn.delete(vim.env.IGIT_NVIM_RECORD)
end

local function clean()
  igit.close()
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "igit" then
      api.nvim_buf_delete(buf, { force = true })
    end
  end
  vim.wait(20, function() return false end)
  if api.nvim_win_is_valid(origin) then
    api.nvim_set_current_win(origin)
  end
  clear_record()
  notices = {}
end

local function test(name, callback)
  clean()
  igit.setup({ command = fixture })
  local ok, err = xpcall(callback, debug.traceback)
  if not ok then
    error(name .. "\n" .. err)
  end
  passed = passed + 1
  print("PASS " .. name)
end

local ok, err = xpcall(function()
  for _, layout in ipairs({ "float", "left", "right", "bottom", "tab" }) do
    test(layout .. " layout, focus, reuse, hide, and exit", function()
      igit.setup({ command = fixture, window = { layout = layout } })
      local tab_count = #api.nvim_list_tabpages()
      local buf = assert(igit.open())
      equal(record(), { temp, "commit" })
      equal(vim.bo[buf].buftype, "terminal")
      local win = api.nvim_get_current_win()
      assert(win ~= origin, "IGit must have its own window")
      local win_config = api.nvim_win_get_config(win)
      equal(win_config.relative, layout == "float" and "editor" or "")
      if layout == "left" or layout == "right" then
        local x = api.nvim_win_get_position(win)[2]
        local source_x = api.nvim_win_get_position(origin)[2]
        assert(layout == "left" and x < source_x or layout == "right" and x > source_x)
      elseif layout == "bottom" then
        assert(api.nvim_win_get_position(win)[1] > api.nvim_win_get_position(origin)[1])
      elseif layout == "tab" then
        equal(#api.nvim_list_tabpages(), tab_count + 1)
      end
      local job = vim.b[buf].terminal_job_id
      equal(igit.open(), buf, "Repeated opens must reuse the terminal")
      equal(api.nvim_get_current_win(), win)
      assert(igit.close())
      equal(api.nvim_get_current_win(), origin, "Close should return focus")
      assert(api.nvim_buf_is_valid(buf), "Hiding must retain the terminal")
      equal(vim.fn.jobwait({ job }, 0), { -1 }, "Hiding must retain the process")
      equal(igit.open(), buf)
      equal(vim.b[buf].terminal_job_id, job)
      vim.fn.chansend(job, "quit\n")
      wait_for(function() return not api.nvim_buf_is_valid(buf) end, "A successful exit must clean its buffer")
      equal(api.nvim_get_current_win(), origin)
      equal(#api.nvim_list_tabpages(), tab_count)
    end)
  end

  test("all panels reach native CLI", function()
    for _, panel in ipairs({ "commit", "log", "push", "branch", "stash" }) do
      clear_record()
      assert(igit.open(panel))
      equal(record(), { temp, panel })
    end
  end)

  test("multiple sessions preserve jobs and the originating file", function()
    local first = assert(igit.open("commit"))
    record()
    local first_job = vim.b[first].terminal_job_id
    clear_record()
    local second = assert(igit.open("log", { file = "%" }))
    assert(first ~= second)
    equal(record(), { temp, "log", "--", file })
    equal(vim.fn.jobwait({ first_job }, 0), { -1 })
    equal(igit.open("commit"), first)
    equal(vim.b[first].terminal_job_id, first_job)
    local second_job = vim.b[second].terminal_job_id
    vim.fn.chansend(second_job, "quit\n")
    wait_for(function() return not api.nvim_buf_is_valid(second) end)
    equal(api.nvim_get_current_buf(), first, "A hidden process exiting must not steal focus")
  end)

  test("argv preserves spaces, Unicode, and shell metacharacters", function()
    igit.setup({ command = { fixture, "--custom", "value with spaces; $(nope)" } })
    assert(igit.open("log", { file = "file with 空格 ; $dollar.txt" }))
    equal(record(), { temp, "--custom", "value with spaces; $(nope)", "log", "--", file })
  end)

  test("dynamic commands resolve on every open but not during setup", function()
    local calls = 0
    igit.setup({ command = function()
      calls = calls + 1
      return fixture
    end })
    equal(calls, 0)
    local buf = assert(igit.open())
    equal(record(), { temp, "commit" })
    equal(calls, 1)
    equal(igit.open(), buf)
    equal(calls, 2, "Cached sessions must still re-evaluate the selector")
  end)

  test("switching executables preserves separate stable and debug sessions", function()
    local debug_fixture = temp .. "/debug igit.sh"
    vim.fn.writefile(vim.fn.readfile(fixture), debug_fixture)
    vim.fn.setfperm(debug_fixture, "rwx------")
    local selected = fixture
    igit.setup({ command = function() return selected end })
    local stable_buf = assert(igit.open())
    record()
    local stable_job = vim.b[stable_buf].terminal_job_id
    assert(igit.close())
    selected = debug_fixture
    clear_record()
    local debug_buf = assert(igit.open())
    equal(record(), { temp, "commit" })
    assert(debug_buf ~= stable_buf, "A new executable needs a different session")
    equal(vim.b[debug_buf].igit.argv, { debug_fixture, "commit" })
    local debug_job = vim.b[debug_buf].terminal_job_id
    equal(vim.fn.jobwait({ stable_job }, 0), { -1 })
    assert(igit.close())
    selected = fixture
    equal(igit.open(), stable_buf)
    equal(vim.b[stable_buf].terminal_job_id, stable_job)
    equal(vim.fn.jobwait({ debug_job }, 0), { -1 })
  end)

  test("dynamic argv is copied before panel and file arguments are appended", function()
    local arguments = { fixture, "--custom", "value with spaces; $(nope)" }
    igit.setup({ command = function() return arguments end })
    assert(igit.open("log", { file = "%" }))
    equal(record(), { temp, "--custom", "value with spaces; $(nope)", "log", "--", file })
    equal(arguments, { fixture, "--custom", "value with spaces; $(nope)" })
  end)

  test("dynamic command errors leave the editor intact and can be retried", function()
    local selected
    igit.setup({ command = function()
      if selected == "error" then error("Selected build unavailable") end
      return selected
    end })
    for _, value in ipairs({ "error", false, {} }) do
      selected = value
      local buf, message = igit.open()
      equal(buf, nil)
      assert(message:find("Could not resolve IGit command", 1, true))
      equal(api.nvim_get_current_win(), origin)
      equal(api.nvim_get_current_buf(), origin_buf)
    end
    selected = fixture
    assert(igit.open())
    equal(record(), { temp, "commit" })
  end)

  test("explicit working directories resolve relative file paths", function()
    local directory = temp .. "/nested 空间"
    vim.fn.mkdir(directory, "p")
    assert(igit.open("log", { cwd = "nested 空间", file = "../file with 空格 ; $dollar.txt" }))
    equal(record(), { directory, "log", "--", file })
  end)

  test("Ex filename escaping round-trips quotes and literal backslashes", function()
    local target = temp .. [[/quote"' \#%[]{}!|<`$*.rs]]
    vim.cmd("Igit log " .. vim.fn.fnameescape(target))
    equal(record(), { temp, "log", "--", target })
  end)

  test("command paths and percent expansion", function()
    vim.cmd("Igit log " .. vim.fn.fnameescape(file))
    equal(record(), { temp, "log", "--", file })
    local buf = api.nvim_get_current_buf()
    vim.cmd("Igit log %")
    equal(api.nvim_get_current_buf(), buf)
    vim.cmd('Igit log "' .. file .. '"')
    equal(api.nvim_get_current_buf(), buf, "Quoted paths must resolve to the same session")
    vim.cmd("Igit log '" .. file .. "'")
    equal(api.nvim_get_current_buf(), buf)
    vim.cmd('Igit log "unclosed')
    assert(notices[#notices].message:find("Unclosed quote", 1, true))
  end)

  test("completion offers panels and escaped file paths", function()
    equal(command.complete("", "Igit ", 5), { "commit", "log", "push", "branch", "stash" })
    equal(command.complete("st", "Igit st", 7), { "stash" })
    equal(command.complete("", "Igit push ", 10), {})
    local completions = command.complete("file", "Igit log file", 13)
    assert(vim.tbl_contains(completions, vim.fn.fnameescape("file with 空格 ; $dollar.txt")))
    local escaped = "Igit log file\\ with"
    completions = command.complete("file\\ with", escaped, #escaped)
    assert(vim.tbl_contains(completions, vim.fn.fnameescape("file with 空格 ; $dollar.txt")))
    local modified = "silent Igit log file"
    completions = command.complete("file", modified, #modified)
    assert(vim.tbl_contains(completions, vim.fn.fnameescape("file with 空格 ; $dollar.txt")))
  end)

  test("resize and layout changes preserve the terminal", function()
    local buf = assert(igit.open("log"))
    record()
    local job = vim.b[buf].terminal_job_id
    local first_width = api.nvim_win_get_width(api.nvim_get_current_win())
    vim.o.columns = 100
    api.nvim_exec_autocmds("VimResized", {})
    assert(api.nvim_win_get_width(api.nvim_get_current_win()) < first_width)
    equal(igit.open("log", { window = { layout = "right", width = 32 } }), buf)
    equal(api.nvim_win_get_width(api.nvim_get_current_win()), 32)
    equal(vim.b[buf].terminal_job_id, job)
    vim.o.columns = 140
  end)

  test("small floats and borderless floats stay inside the editor", function()
    vim.o.columns = 20
    vim.o.lines = 8
    local buf = assert(igit.open("log", { window = { width = 200, height = 100, border = "none" } }))
    record()
    local win = api.nvim_get_current_win()
    assert(api.nvim_win_get_width(win) <= vim.o.columns)
    assert(api.nvim_win_get_height(win) <= vim.o.lines - vim.o.cmdheight)
    assert(igit.close())
    assert(api.nvim_buf_is_valid(buf))
    vim.o.columns = 140
    vim.o.lines = 45
  end)

  test("a changed invocation window receives focus when the session closes", function()
    local buf = assert(igit.open())
    record()
    igit.close()
    vim.cmd.vsplit()
    local second_origin = api.nvim_get_current_win()
    equal(igit.open(), buf)
    igit.close()
    equal(api.nvim_get_current_win(), second_origin)
    api.nvim_win_close(second_origin, true)
  end)

  test("the last ordinary window can hide a terminal without stopping it", function()
    local saved_origin = origin
    local buf = assert(igit.open("log", { window = { layout = "right" } }))
    record()
    local terminal_win = api.nvim_get_current_win()
    local job = vim.b[buf].terminal_job_id
    api.nvim_win_close(saved_origin, true)
    assert(igit.close())
    equal(api.nvim_get_current_win(), terminal_win)
    equal(api.nvim_get_current_buf(), origin_buf)
    equal(vim.fn.jobwait({ job }, 0), { -1 })
    origin = terminal_win
  end)

  test("missing executable leaves the editor intact", function()
    igit.setup({ command = temp .. "/does-not-exist" })
    local buf, message = igit.open()
    equal(buf, nil)
    assert(message:find("executable not found", 1, true))
    equal(api.nvim_get_current_win(), origin)
    equal(api.nvim_get_current_buf(), origin_buf)
  end)

  test("failed jobs retain output and can be retried", function()
    local buf = assert(igit.open())
    record()
    vim.fn.chansend(vim.b[buf].terminal_job_id, "fail\n")
    wait_for(function() return #notices > 0 end)
    assert(notices[#notices].message:find("exited with code 23", 1, true))
    assert(api.nvim_buf_is_valid(buf))
    clear_record()
    local retry = assert(igit.open())
    assert(retry ~= buf)
    record()
  end)

  test("an invalid interpreter reports asynchronous spawn failure", function()
    local broken = temp .. "/broken"
    vim.fn.writefile({ "#!/does/not/exist", "exit 0" }, broken)
    vim.fn.setfperm(broken, "rwx------")
    igit.setup({ command = broken })
    local buf = assert(igit.open())
    wait_for(function() return #notices > 0 end)
    assert(notices[#notices].message:find("exited with code", 1, true))
    assert(api.nvim_buf_is_valid(buf), "Failed terminal output must remain available")
  end)

  test("synchronous spawn errors clean up their window and buffer", function()
    local original_termopen = vim.fn.termopen
    vim.fn.termopen = function() return -1 end
    local buf, message = igit.open()
    vim.fn.termopen = original_termopen
    equal(buf, nil)
    assert(message:find("Could not start IGit", 1, true))
    equal(api.nvim_get_current_win(), origin)
  end)

  test("manual window closing and buffer deletion do not leave stale sessions", function()
    local buf = assert(igit.open())
    record()
    local job = vim.b[buf].terminal_job_id
    api.nvim_win_close(api.nvim_get_current_win(), true)
    equal(igit.open(), buf)
    api.nvim_buf_delete(buf, { force = true })
    wait_for(function() return vim.fn.jobwait({ job }, 0)[1] ~= -1 end)
    clear_record()
    local next_buf = assert(igit.open())
    assert(next_buf ~= buf)
    record()
  end)

  test("deleting a terminal buffer also removes its managed split", function()
    local count = #api.nvim_list_wins()
    local buf = assert(igit.open("log", { window = { layout = "right" } }))
    record()
    api.nvim_buf_delete(buf, { force = true })
    wait_for(function() return #api.nvim_list_wins() == count end, "Deleting an IGit buffer left an empty split")
    equal(api.nvim_get_current_win(), origin)
  end)

  test("invalid input and unnamed source buffers are rejected", function()
    equal(igit.open("unknown"), nil)
    equal(igit.open("push", { file = file }), nil)
    equal(igit.open("log", { cwd = temp .. "/missing" }), nil)
    equal(igit.open("log", { window = { layout = "unknown" } }), nil)
    vim.cmd.enew()
    equal(igit.open("log", { file = "%" }), nil)
    api.nvim_win_set_buf(origin, origin_buf)
  end)

  local bridge = temp .. "/fake edit bridge.sh"
  vim.fn.writefile({
    '#!/bin/sh',
    'printf "%s\\n" "$IGIT_NVIM_SESSION" > "$IGIT_NVIM_RECORD"',
    'while IFS= read -r request; do',
    '  printf "\\033]51;igit-edit;%s\\007" "$request"',
    'done',
  }, bridge)
  vim.fn.setfperm(bridge, "rwx------")
  local edit_target = temp .. "/edit 文件 | # %.txt"
  vim.fn.writefile({ "saved target" }, edit_target)
  local function edit_request(buf, token, path)
    vim.fn.chansend(vim.b[buf].terminal_job_id, vim.json.encode({ version = 1, session = token, path = path }) .. "\n")
  end

  local revision_bridge = temp .. "/fake revision bridge.sh"
  vim.fn.writefile({
    '#!/bin/sh',
    'printf "%s\\n" "$IGIT_NVIM_SESSION" > "$IGIT_NVIM_RECORD"',
    'while IFS= read -r request; do',
    '  printf "\\033]51;igit-show-revision;%s\\007" "$request"',
    'done',
  }, revision_bridge)
  vim.fn.setfperm(revision_bridge, "rwx------")

  local function run_git(directory, arguments)
    local argv = { "git", "-C", directory }
    vim.list_extend(argv, arguments)
    local result = vim.system(argv, { text = true }):wait()
    assert(result.code == 0, table.concat(argv, " ") .. "\n" .. tostring(result.stderr))
    return (result.stdout or ""):gsub("%s+$", "")
  end

  local function write_bytes(path, value)
    local fd = assert(vim.uv.fs_open(path, "w", 420))
    assert(vim.uv.fs_write(fd, value, -1))
    assert(vim.uv.fs_close(fd))
  end

  local history_repo = temp .. "/history repo"
  vim.fn.mkdir(history_repo .. "/src", "p")
  run_git(history_repo, { "init", "-q" })
  run_git(history_repo, { "config", "user.email", "igit@example.com" })
  run_git(history_repo, { "config", "user.name", "IGit Test" })
  vim.fn.writefile({ "export const user = 'first';" }, history_repo .. "/src/user.ts")
  vim.fn.writefile({ "original rename" }, history_repo .. "/src/rename-me.ts")
  vim.fn.writefile({ "deleted later" }, history_repo .. "/src/deleted.ts")
  run_git(history_repo, { "add", "-A" })
  run_git(history_repo, { "commit", "-qm", "first" })
  local revision_one = run_git(history_repo, { "rev-parse", "HEAD" })
  vim.fn.writefile({ "export const user = 'second';", "// 中文" }, history_repo .. "/src/user.ts")
  assert(vim.uv.fs_rename(history_repo .. "/src/rename-me.ts", history_repo .. "/src/renamed-away.ts"))
  assert(vim.uv.fs_unlink(history_repo .. "/src/deleted.ts"))
  run_git(history_repo, { "add", "-A" })
  run_git(history_repo, { "commit", "-qm", "second" })
  local revision_two = run_git(history_repo, { "rev-parse", "HEAD" })
  write_bytes(history_repo .. "/binary.dat", "prefix\0suffix\n")
  write_bytes(history_repo .. "/invalid-utf8.dat", string.char(0xff, 0xfe, 0x0a))
  vim.fn.writefile({ string.rep("x", 512 * 1024 + 1) }, history_repo .. "/large.txt")
  local newline_cases = {
    { path = "crlf.txt", content = "first\r\nsecond\r\n", lines = { "first", "second" }, format = "dos", eol = true },
    { path = "crlf-no-final.txt", content = "first\r\nsecond\r", lines = { "first", "second\r" }, format = "dos", eol = false },
    { path = "mixed.txt", content = "first\r\nsecond\nthird\r\n", lines = { "first\r", "second", "third\r" }, format = "unix", eol = true },
    { path = "mixed-no-final.txt", content = "first\nsecond\r\nthird\r", lines = { "first", "second\r", "third\r" }, format = "unix", eol = false },
    { path = "no-final.txt", content = "first\nsecond", lines = { "first", "second" }, format = "unix", eol = false },
    { path = "empty.txt", content = "", lines = { "" }, format = "unix", eol = false },
    { path = "bare-cr.txt", content = "first\rsecond\r", lines = { "first\rsecond\r" }, format = "unix", eol = false },
  }
  vim.fn.writefile({ "*.txt -text" }, history_repo .. "/.gitattributes")
  for _, case in ipairs(newline_cases) do
    write_bytes(history_repo .. "/" .. case.path, case.content)
  end
  run_git(history_repo, { "add", "-A" })
  run_git(history_repo, { "commit", "-qm", "edge cases" })
  local asset_revision = run_git(history_repo, { "rev-parse", "HEAD" })
  run_git(history_repo, { "update-index", "--add", "--cacheinfo", "160000," .. revision_one .. ",vendor/module" })
  run_git(history_repo, { "commit", "-qm", "gitlink" })
  local submodule_revision = run_git(history_repo, { "rev-parse", "HEAD" })
  history_repo = assert(vim.uv.fs_realpath(history_repo))

  local function revision_request(buf, token, repo, path, revision)
    vim.fn.chansend(vim.b[buf].terminal_job_id, vim.json.encode({
      version = 1,
      session = token,
      repo = repo,
      path = path,
      revision = revision,
    }) .. "\n")
  end

  test("file edit hides the float, reuses unsaved buffers and retains the job", function()
    api.nvim_win_set_buf(origin, origin_buf)
    local target = vim.fn.bufadd(edit_target)
    vim.fn.bufload(target)
    api.nvim_buf_set_lines(target, 0, -1, false, { "unsaved target" })
    igit.setup({ command = bridge })
    local buf = assert(igit.open())
    local token, win, job = record()[1], api.nvim_get_current_win(), vim.b[buf].terminal_job_id
    assert(token ~= "", "The parent editor bridge was not advertised")
    edit_request(buf, token, edit_target)
    wait_for(function() return api.nvim_get_current_buf() == target end)
    assert(not api.nvim_win_is_valid(win), "File editing must hide the float")
    equal(api.nvim_buf_get_lines(target, 0, -1, false), { "unsaved target" })
    equal(vim.fn.readfile(edit_target), { "saved target" })
    equal(vim.fn.jobwait({ job }, 0), { -1 })
    equal(igit.open(), buf)
    equal(vim.b[buf].terminal_job_id, job)
    local history = assert(igit.open("log", { file = "%" }))
    equal(vim.b[history].igit.argv, { bridge, "log", "--", edit_target })
    igit.close()
    vim.bo[target].modified = false
    api.nvim_win_set_buf(origin, origin_buf)
  end)

  for _, layout in ipairs({ "left", "right", "bottom", "tab" }) do
    test("file edit in " .. layout .. " focuses the source and preserves the IGit window", function()
      api.nvim_win_set_buf(origin, origin_buf)
      igit.setup({ command = bridge, window = { layout = layout } })
      local buf = assert(igit.open())
      local token, win = record()[1], api.nvim_get_current_win()
      edit_request(buf, token, edit_target)
      wait_for(function() return api.nvim_buf_get_name(api.nvim_get_current_buf()) == edit_target end)
      equal(api.nvim_get_current_win(), origin)
      assert(api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf)
      equal(vim.fn.jobwait({ vim.b[buf].terminal_job_id }, 0), { -1 })
      api.nvim_win_set_buf(origin, origin_buf)
    end)
  end

  test("a blocked file switch keeps the float, unsaved source and running job", function()
    api.nvim_win_set_buf(origin, origin_buf)
    vim.o.hidden = false
    api.nvim_buf_set_lines(origin_buf, 0, -1, false, { "unsaved source" })
    igit.setup({ command = bridge })
    local buf = assert(igit.open())
    local token, win = record()[1], api.nvim_get_current_win()
    edit_request(buf, token, edit_target)
    wait_for(function() return #notices > 0 end)
    equal(api.nvim_get_current_win(), win)
    equal(api.nvim_buf_get_lines(origin_buf, 0, -1, false), { "unsaved source" })
    assert(notices[#notices].message:find("Could not edit file", 1, true))
    equal(vim.fn.jobwait({ vim.b[buf].terminal_job_id }, 0), { -1 })
    vim.o.hidden = true
    api.nvim_buf_set_lines(origin_buf, 0, -1, false, { "test" })
    vim.bo[origin_buf].modified = false
    igit.close()
  end)

  test("Nvim 0.10 requests recover an editing window after the source split closes", function()
    api.nvim_win_set_buf(origin, origin_buf)
    igit.setup({ command = bridge, window = { layout = "right" } })
    local buf = assert(igit.open())
    local token, win = record()[1], api.nvim_get_current_win()
    api.nvim_win_close(origin, true)
    local sequence = "\027]51;igit-edit;" .. vim.json.encode({ version = 1, session = token, path = edit_target })
    api.nvim_exec_autocmds("TermRequest", { group = "Igit", buffer = buf, data = sequence })
    wait_for(function() return api.nvim_buf_get_name(api.nvim_get_current_buf()) == edit_target end)
    assert(api.nvim_win_is_valid(win) and api.nvim_get_current_win() ~= win)
    equal(vim.fn.jobwait({ vim.b[buf].terminal_job_id }, 0), { -1 })
    origin = api.nvim_get_current_win()
    api.nvim_win_set_buf(origin, origin_buf)
  end)

  test("file history opens read-only revision buffers and preserves unsaved files", function()
    api.nvim_win_set_buf(origin, origin_buf)
    vim.o.hidden = true
    local working_path = history_repo .. "/src/user.ts"
    local working_buf = vim.fn.bufadd(working_path)
    vim.fn.bufload(working_buf)
    api.nvim_win_set_buf(origin, working_buf)
    api.nvim_buf_set_lines(working_buf, 0, -1, false, { "unsaved working content" })
    local disk_before = vim.fn.readfile(working_path)
    local status_before = run_git(history_repo, { "status", "--porcelain" })
    igit.setup({ command = revision_bridge })
    local term = assert(igit.open())
    local token, term_win = record()[1], api.nvim_get_current_win()
    revision_request(term, token, history_repo, "src/user.ts", revision_one)
    wait_for(function() return vim.b[api.nvim_get_current_buf()].igit_revision ~= nil end)
    local revision_one_buf = api.nvim_get_current_buf()
    local revision_one_name = api.nvim_buf_get_name(revision_one_buf)
    equal(api.nvim_get_current_win(), origin)
    assert(not api.nvim_win_is_valid(term_win), "Revision viewing must hide the float")
    equal(api.nvim_buf_get_lines(revision_one_buf, 0, -1, false), { "export const user = 'first';" })
    equal(vim.bo[revision_one_buf].buftype, "nofile")
    equal(vim.bo[revision_one_buf].buflisted, true)
    equal(vim.bo[revision_one_buf].swapfile, false)
    equal(vim.bo[revision_one_buf].readonly, true)
    equal(vim.bo[revision_one_buf].modifiable, false)
    equal(vim.bo[revision_one_buf].modified, false)
    equal(vim.bo[revision_one_buf].endofline, true)
    equal(vim.bo[revision_one_buf].filetype, "typescript")
    assert(not pcall(api.nvim_buf_set_lines, revision_one_buf, 0, -1, false, { "replacement" }))
    equal(api.nvim_buf_get_lines(revision_one_buf, 0, -1, false), { "export const user = 'first';" })
    assert(revision_one_name:find(revision_one, 1, true), "The buffer identity must include the full revision")
    equal(vim.fn.fnamemodify(revision_one_name, ":t"), "user.ts (" .. revision_one:sub(1, 8) .. ")")
    equal(vim.b[revision_one_buf].igit_revision, {
      repo = history_repo,
      path = "src/user.ts",
      revision = revision_one,
      title = "user.ts (" .. revision_one:sub(1, 8) .. ")",
    })
    equal(api.nvim_buf_get_lines(working_buf, 0, -1, false), { "unsaved working content" })
    equal(vim.bo[working_buf].modified, true)
    equal(vim.fn.readfile(working_path), disk_before)
    equal(run_git(history_repo, { "status", "--porcelain" }), status_before)
    equal(vim.fn.jobwait({ vim.b[term].terminal_job_id }, 0), { -1 })

    equal(igit.open(), term)
    vim.b[revision_one_buf].revision_test_marker = true
    vim.bo[revision_one_buf].modifiable = true
    vim.bo[revision_one_buf].readonly = false
    revision_request(term, token, history_repo, "src/user.ts", revision_one)
    wait_for(function() return api.nvim_get_current_buf() == revision_one_buf end)
    equal(vim.b[revision_one_buf].revision_test_marker, true)
    equal(vim.bo[revision_one_buf].modifiable, false)
    equal(vim.bo[revision_one_buf].readonly, true)

    equal(igit.open(), term)
    revision_request(term, token, history_repo, "src/user.ts", revision_two)
    wait_for(function()
      local buf = api.nvim_get_current_buf()
      return vim.b[buf].igit_revision and vim.b[buf].igit_revision.revision == revision_two
    end)
    local revision_two_buf = api.nvim_get_current_buf()
    assert(revision_two_buf ~= revision_one_buf)
    equal(api.nvim_buf_get_lines(revision_two_buf, 0, -1, false), {
      "export const user = 'second';",
      "// 中文",
    })
    equal(vim.fn.fnamemodify(api.nvim_buf_get_name(revision_two_buf), ":t"), "user.ts (" .. revision_two:sub(1, 8) .. ")")
    equal(igit.open(), term)
    assert(igit.close())
    equal(api.nvim_get_current_win(), origin)
    equal(api.nvim_win_get_buf(origin), revision_two_buf)
    vim.bo[working_buf].modified = false
    api.nvim_win_set_buf(origin, origin_buf)
    api.nvim_buf_delete(working_buf, { force = true })
  end)

  test("revision buffers preserve CRLF, mixed endings, missing final newline and empty blobs", function()
    api.nvim_win_set_buf(origin, origin_buf)
    igit.setup({ command = revision_bridge })
    local term = assert(igit.open())
    local token = record()[1]
    for _, case in ipairs(newline_cases) do
      equal(igit.open(), term)
      revision_request(term, token, history_repo, case.path, asset_revision)
      wait_for(function()
        local metadata = vim.b[api.nvim_get_current_buf()].igit_revision
        return metadata and metadata.path == case.path
      end)
      local buf = api.nvim_get_current_buf()
      local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
      equal(lines, case.lines, case.path)
      equal(vim.bo[buf].fileformat, case.format, case.path)
      equal(vim.bo[buf].endofline, case.eol, case.path)
      equal(vim.bo[buf].fixendofline, false, case.path)
      local separator = vim.bo[buf].fileformat == "dos" and "\r\n" or "\n"
      local reconstructed = table.concat(lines, separator) .. (vim.bo[buf].endofline and separator or "")
      equal(reconstructed, case.content, "Revision bytes changed for " .. case.path)
    end
    api.nvim_win_set_buf(origin, origin_buf)
  end)

  test("revision view keeps an IGit split and can be revisited", function()
    api.nvim_win_set_buf(origin, origin_buf)
    igit.setup({ command = revision_bridge, window = { layout = "right" } })
    local term = assert(igit.open())
    local token, term_win = record()[1], api.nvim_get_current_win()
    revision_request(term, token, history_repo, "src/user.ts", revision_two)
    wait_for(function()
      local buf = api.nvim_get_current_buf()
      return vim.b[buf].igit_revision and vim.b[buf].igit_revision.revision == revision_two
    end)
    equal(api.nvim_get_current_win(), origin)
    assert(api.nvim_win_is_valid(term_win) and api.nvim_win_get_buf(term_win) == term)
    equal(vim.fn.jobwait({ vim.b[term].terminal_job_id }, 0), { -1 })
    api.nvim_win_set_buf(origin, origin_buf)
    igit.close()
  end)

  test("invalid revision requests and non-file blobs stay inside IGit", function()
    api.nvim_win_set_buf(origin, origin_buf)
    igit.setup({ command = revision_bridge })
    local term = assert(igit.open())
    local token, term_win = record()[1], api.nvim_get_current_win()
    local buffer_count = #api.nvim_list_bufs()
    revision_request(term, "foreign-session", history_repo, "src/user.ts", revision_one)
    revision_request(term, token, "relative/repo", "src/user.ts", revision_one)
    revision_request(term, token, history_repo, "../outside.ts", revision_one)
    revision_request(term, token, history_repo, "src/user.ts", revision_one:sub(1, 7))
    vim.fn.chansend(vim.b[term].terminal_job_id, "not-json\n")
    vim.wait(100, function() return false end)
    equal(api.nvim_get_current_win(), term_win)
    equal(#notices, 0)
    equal(#api.nvim_list_bufs(), buffer_count)

    local function expect_failure(repo, path, revision, message)
      local notice_count = #notices
      revision_request(term, token, repo, path, revision)
      wait_for(function() return #notices > notice_count end)
      assert(notices[#notices].message:find(message, 1, true), notices[#notices].message)
      equal(api.nvim_get_current_win(), term_win)
    end
    expect_failure(history_repo, "src/missing.ts", revision_one, "Could not show file revision")
    expect_failure(history_repo .. "/missing", "src/user.ts", revision_one, "repository is unavailable")
    expect_failure(history_repo, "binary.dat", asset_revision, "binary data")
    expect_failure(history_repo, "invalid-utf8.dat", asset_revision, "not valid UTF-8")
    expect_failure(history_repo, "large.txt", asset_revision, "512 KiB")
    expect_failure(history_repo, "vendor/module", submodule_revision, "not a file")
    equal(vim.fn.jobwait({ vim.b[term].terminal_job_id }, 0), { -1 })
    igit.close()
  end)

  test("renamed and deleted working files retain historical revision views", function()
    api.nvim_win_set_buf(origin, origin_buf)
    equal(vim.fn.filereadable(history_repo .. "/src/rename-me.ts"), 0)
    equal(vim.fn.filereadable(history_repo .. "/src/renamed-away.ts"), 1)
    equal(vim.fn.filereadable(history_repo .. "/src/deleted.ts"), 0)
    local status_before = run_git(history_repo, { "status", "--porcelain" })
    igit.setup({ command = revision_bridge })
    local term = assert(igit.open())
    local token, term_win = record()[1], api.nvim_get_current_win()
    revision_request(term, token, history_repo, "src/rename-me.ts", revision_one)
    wait_for(function()
      local metadata = vim.b[api.nvim_get_current_buf()].igit_revision
      return metadata and metadata.path == "src/rename-me.ts"
    end)
    equal(api.nvim_get_current_win(), origin)
    assert(not api.nvim_win_is_valid(term_win))
    local renamed_buf = api.nvim_get_current_buf()
    equal(api.nvim_buf_get_lines(renamed_buf, 0, -1, false), { "original rename" })
    equal(vim.fn.fnamemodify(api.nvim_buf_get_name(renamed_buf), ":t"), "rename-me.ts (" .. revision_one:sub(1, 8) .. ")")
    equal(vim.bo[renamed_buf].filetype, "typescript")

    equal(igit.open(), term)
    revision_request(term, token, history_repo, "src/deleted.ts", revision_one)
    wait_for(function()
      local metadata = vim.b[api.nvim_get_current_buf()].igit_revision
      return metadata and metadata.path == "src/deleted.ts"
    end)
    local deleted_buf = api.nvim_get_current_buf()
    equal(api.nvim_buf_get_lines(deleted_buf, 0, -1, false), { "deleted later" })
    assert(deleted_buf ~= renamed_buf)
    equal(vim.fn.filereadable(history_repo .. "/src/rename-me.ts"), 0)
    equal(vim.fn.filereadable(history_repo .. "/src/deleted.ts"), 0)
    equal(run_git(history_repo, { "status", "--porcelain" }), status_before)
    equal(vim.fn.jobwait({ vim.b[term].terminal_job_id }, 0), { -1 })
    igit.close()
    assert(api.nvim_win_is_valid(origin))
    api.nvim_win_set_buf(origin, origin_buf)
  end)

  test("blocked revision switches and delayed requests preserve editor focus", function()
    api.nvim_win_set_buf(origin, origin_buf)
    vim.o.hidden = false
    api.nvim_buf_set_lines(origin_buf, 0, -1, false, { "unsaved source" })
    igit.setup({ command = revision_bridge })
    local term = assert(igit.open())
    local token, term_win = record()[1], api.nvim_get_current_win()
    revision_request(term, token, history_repo, "src/user.ts", revision_one)
    wait_for(function() return #notices > 0 end)
    assert(notices[#notices].message:find("Could not show file revision", 1, true), vim.inspect(notices))
    equal(api.nvim_get_current_win(), term_win)
    equal(api.nvim_buf_get_lines(origin_buf, 0, -1, false), { "unsaved source" })
    equal(vim.fn.jobwait({ vim.b[term].terminal_job_id }, 0), { -1 })
    vim.o.hidden = true
    vim.bo[origin_buf].modified = false
    api.nvim_buf_set_lines(origin_buf, 0, -1, false, { "test" })
    vim.bo[origin_buf].modified = false

    local sequence = "\027]51;igit-show-revision;" .. vim.json.encode({
      version = 1,
      session = token,
      repo = history_repo,
      path = "src/user.ts",
      revision = revision_one,
    }) .. "\a"
    api.nvim_exec_autocmds("TermRequest", { group = "Igit", buffer = term, data = sequence })
    igit.close()
    vim.wait(200, function() return false end)
    equal(api.nvim_get_current_buf(), origin_buf)
    equal(#notices, 1)
  end)

  test("an in-flight revision request cannot open after hide and reopen", function()
    api.nvim_win_set_buf(origin, origin_buf)
    local real_git = vim.fn.exepath("git")
    local old_path = vim.env.PATH or ""
    local marker = temp .. "/slow git started"
    local slow_directory = temp .. "/slow git bin"
    vim.fn.mkdir(slow_directory, "p")
    local slow_git = slow_directory .. "/git"
    vim.fn.writefile({
      '#!/bin/sh',
      '[ "$GIT_OPTIONAL_LOCKS" = "0" ] && [ "$GIT_NO_LAZY_FETCH" = "1" ] || exit 24',
      'if [ "$1" = "-C" ] && [ "$3" = "cat-file" ]; then',
      '  printf "started\\n" >> "$IGIT_TEST_SLOW_MARKER"',
      '  sleep 0.3',
      'fi',
      'exec "$IGIT_TEST_REAL_GIT" "$@"',
    }, slow_git)
    vim.fn.setfperm(slow_git, "rwx------")
    vim.env.IGIT_TEST_REAL_GIT = real_git
    vim.env.IGIT_TEST_SLOW_MARKER = marker
    vim.env.PATH = slow_directory .. ":" .. old_path
    igit.setup({ command = revision_bridge })
    local term = assert(igit.open())
    local token = record()[1]
    revision_request(term, token, history_repo, "src/user.ts", asset_revision)
    wait_for(function() return vim.fn.filereadable(marker) == 1 end, "Slow Git request did not start")
    assert(igit.close())
    equal(igit.open(), term)
    local reopened_win = api.nvim_get_current_win()
    vim.wait(600, function() return false end)
    equal(api.nvim_get_current_win(), reopened_win)
    equal(api.nvim_get_current_buf(), term)
    equal(#notices, 0)
    for _, buf in ipairs(api.nvim_list_bufs()) do
      local metadata = vim.b[buf].igit_revision
      assert(not metadata or metadata.repo ~= history_repo
        or metadata.path ~= "src/user.ts" or metadata.revision ~= asset_revision)
    end
    vim.env.PATH = old_path
    vim.env.IGIT_TEST_REAL_GIT = nil
    vim.env.IGIT_TEST_SLOW_MARKER = nil
    igit.close()
    api.nvim_win_set_buf(origin, origin_buf)
  end)

  test("malformed, foreign and delayed edit requests cannot steal editor focus", function()
    api.nvim_win_set_buf(origin, origin_buf)
    igit.setup({ command = bridge })
    local buf = assert(igit.open())
    local token, win = record()[1], api.nvim_get_current_win()
    vim.fn.chansend(vim.b[buf].terminal_job_id, "not-json\n")
    edit_request(buf, "foreign-session", edit_target)
    edit_request(buf, token, "relative.txt")
    vim.wait(50, function() return false end)
    equal(api.nvim_get_current_win(), win)
    equal(#notices, 0)
    edit_request(buf, token, temp .. "/missing.txt")
    wait_for(function() return #notices > 0 end)
    equal(api.nvim_get_current_win(), win)
    assert(not api.nvim_buf_is_valid(vim.fn.bufnr(temp .. "/missing.txt")))
    igit.close()
    local delayed_target = temp .. "/delayed edit target.txt"
    vim.fn.writefile({ "must remain unopened" }, delayed_target)
    vim.bo[origin_buf].buflisted = false
    edit_request(buf, token, delayed_target)
    vim.wait(50, function() return false end)
    equal(api.nvim_get_current_buf(), origin_buf)
    equal(vim.fn.bufnr(delayed_target), -1, "Delayed edit must not create a buffer")
    equal(vim.bo[origin_buf].buflisted, false, "Delayed edit must not relist the source")
    vim.bo[origin_buf].buflisted = true
  end)

  test("lowercase abbreviation is interactive and preserves other contexts", function()
    -- Feed real command-line input so abbreviation conditions run in cmdline mode.
    local function feed(keys)
      api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
    end
    feed(":igit<CR>")
    equal(record(), { temp, "commit" })
    igit.close()
    feed(":let g:igit_alias_argument = 'igit'<CR>")
    equal(vim.g.igit_alias_argument, "igit")
    feed("/igit<Esc>")
    -- Aborted searches are recorded in search history and must not be rewritten.
    equal(vim.fn.histget("/", -1), "igit")
    igit.setup({ command = fixture, command_alias = false })
    equal(vim.fn.maparg("igit", "c", true), "")
    vim.cmd("cnoreabbrev igit UserAlias")
    igit.setup({ command = fixture })
    equal(vim.fn.maparg("igit", "c", true), "UserAlias")
    igit.setup({ command = fixture, command_alias = false })
    equal(vim.fn.maparg("igit", "c", true), "UserAlias")
    vim.cmd("cunabbrev igit")
  end)
end, debug.traceback)

clean()
vim.fn.delete(temp, "rf")
if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
else
  print("Passed " .. passed .. " tests")
  vim.cmd("qa!")
end
