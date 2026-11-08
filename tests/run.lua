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
    edit_request(buf, token, edit_target)
    vim.wait(50, function() return false end)
    equal(api.nvim_get_current_buf(), origin_buf)
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
