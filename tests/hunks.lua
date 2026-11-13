local api = vim.api
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.hidden = true
local git = require("igit.git")
local hunks = require("igit.hunks")
local temp = vim.fn.tempname() .. " igit hunks 中文"
vim.fn.mkdir(temp, "p")
local notices, passed, sequence = {}, 0, 0
vim.notify = function(message)
  notices[#notices + 1] = message
end

local function equal(actual, expected)
  assert(vim.deep_equal(actual, expected), "Expected " .. vim.inspect(expected) .. "\nActual " .. vim.inspect(actual))
end

local function wait_for(condition)
  assert(vim.wait(5000, condition, 10), "Timed out; notices: " .. vim.inspect(notices))
end

local function run(repo, args, options)
  local argv = { "git", "--literal-pathspecs", "-C", repo }
  vim.list_extend(argv, args)
  local result = vim.system(argv, vim.tbl_extend("force", { text = false }, options or {})):wait()
  assert(result.code == 0, result.stderr)
  return result.stdout
end

local function write(path, text)
  local file = assert(io.open(path, "wb"))
  file:write(text)
  file:close()
end

local function read(path)
  local file = assert(io.open(path, "rb"))
  local text = file:read("*a")
  file:close()
  return text
end

local function refresh(buf)
  for attempt = 1, 3 do
    local finished, failure
    hunks.refresh(buf, function(err)
      failure, finished = err, true
    end)
    wait_for(function() return finished end)
    if not failure then
      return
    end
    assert(attempt < 3 and failure:find("buffer changed", 1, true), failure)
  end
end

local function setup(initial, name, unborn)
  sequence = sequence + 1
  local repo = temp .. "/repo " .. sequence
  vim.fn.mkdir(repo, "p")
  run(repo, { "init", "--quiet" })
  run(repo, { "config", "user.name", "IGit Test" })
  run(repo, { "config", "user.email", "test@example.invalid" })
  run(repo, { "config", "core.autocrlf", "false" })
  name = name or "file with 中文 ; $literal.txt"
  write(repo .. "/" .. name, initial)
  write(repo .. "/other.txt", "other original\n")
  if not unborn then
    run(repo, { "add", "--", name, "other.txt" })
    run(repo, { "commit", "--quiet", "-m", "initial" })
  end
  vim.cmd.edit(vim.fn.fnameescape(repo .. "/" .. name))
  local buf = api.nvim_get_current_buf()
  hunks.setup({ debounce = 10 })
  notices = {}
  refresh(buf)
  return repo, buf, name
end

local function set_text(buf, text)
  local lines = vim.split(text, "\n", { plain = true })
  local eol = text:sub(-1) == "\n"
  if eol then
    table.remove(lines)
  end
  if #lines == 0 then
    lines = { "" }
  end
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].endofline = eol
end

local function index(repo, path)
  return run(repo, { "show", ":" .. path })
end

local function perform(method, line)
  if type(line) ~= "table" then
    api.nvim_win_set_cursor(0, { line, 0 })
  end
  local finished = false
  local buf = api.nvim_get_current_buf()
  local autocmd = api.nvim_create_autocmd("User", {
    pattern = "IgitChanged",
    callback = function(event)
      if event.data and event.data.buf == buf then
        finished = true
      end
    end,
  })
  assert(hunks[method](type(line) == "table" and line or nil))
  wait_for(function() return finished or #notices > 0 end)
  api.nvim_del_autocmd(autocmd)
  assert(#notices == 0, vim.inspect(notices))
  refresh(buf)
end

local function test(name, callback)
  local ok, err = xpcall(callback, debug.traceback)
  assert(ok, name .. "\n" .. tostring(err))
  passed = passed + 1
  print("PASS " .. name)
end

local function numbered()
  local lines = {}
  for number = 1, 24 do
    lines[#lines + 1] = "line " .. number
  end
  return table.concat(lines, "\n") .. "\n"
end

local ok, err = xpcall(function()
  test("signs distinguish add, change and deletion and honor configuration", function()
    local _, buf = setup(numbered())
    local text = numbered():gsub("line 3\n", "line 3\nadded\n"):gsub("line 12\n", "changed\n"):gsub("line 22\n", "")
    set_text(buf, text)
    hunks.setup({
      debounce = 10, signs = { add = "+", change = "~", delete = "-" },
      colors = { add = "#112233", change = "#445566", delete = "#778899" },
    })
    refresh(buf)
    local list = hunks.get_hunks(buf)
    equal(#list, 3)
    equal(vim.tbl_map(function(hunk) return hunk.type end, list), { "add", "change", "delete" })
    local marks = api.nvim_buf_get_extmarks(buf, api.nvim_create_namespace("igit.hunks"), 0, -1, { details = true })
    equal(vim.tbl_map(function(mark) return vim.trim(mark[4].sign_text) end, marks), { "+", "~", "-" })
    equal(api.nvim_get_hl(0, { name = "IgitHunkAdd" }).fg, 0x112233)
    hunks.setup({ enabled = false })
    equal(api.nvim_buf_get_extmarks(buf, api.nvim_create_namespace("igit.hunks"), 0, -1, {}), {})
  end)

  test("stage and unstage isolate the reviewed hunk and unrelated staged file", function()
    local original = numbered()
    local repo, buf, path = setup(original)
    write(repo .. "/other.txt", "other staged\n")
    run(repo, { "add", "--", "other.txt" })
    local staged = original:gsub("line 2\n", "existing staged\n")
    write(repo .. "/" .. path, staged)
    run(repo, { "add", "--", path })
    local working = staged:gsub("line 12\n", "selected unsaved\n"):gsub("line 23\n", "unselected unsaved\n")
    set_text(buf, working)
    refresh(buf)
    equal(#hunks.get_hunks(buf), 2)
    equal(#hunks.get_hunks(buf, true), 1)
    perform("stage_hunk", 12)
    local expected = staged:gsub("line 12\n", "selected unsaved\n")
    equal(index(repo, path), expected)
    equal(index(repo, "other.txt"), "other staged\n")
    equal(git.text(buf), working)
    equal(table.concat(vim.fn.readfile(repo .. "/" .. path), "\n") .. "\n", staged)
    equal(#hunks.get_hunks(buf), 1)
    perform("unstage_hunk", 12)
    equal(index(repo, path), staged)
    equal(index(repo, "other.txt"), "other staged\n")
    equal(git.text(buf), working)
  end)

  test("unstage maps staged positions through unsaved insertions and deletions", function()
    for _, insertion in ipairs({ true, false }) do
      local original = numbered()
      local repo, buf, path = setup(original)
      local staged = original:gsub("line 12\n", "staged twelve\n")
      write(repo .. "/" .. path, staged)
      run(repo, { "add", "--", path })
      local working = insertion and ("new first\nnew second\n" .. staged) or staged:gsub("^line 1\nline 2\nline 3\n", "")
      local position = insertion and 14 or 9
      set_text(buf, working)
      refresh(buf)
      equal(hunks.get_hunks(buf, true)[1].start, position)
      perform("unstage_hunk", position)
      equal(index(repo, path), original)
      equal(git.text(buf), working)
    end
  end)

  test("reset is undoable and preserves disk and the real index", function()
    local original = numbered()
    local repo, buf, path = setup(original)
    local working = original:gsub("line 8\n", "reset this\n"):gsub("line 20\n", "keep this\n")
    set_text(buf, working)
    refresh(buf)
    api.nvim_buf_call(buf, function() vim.cmd("let &undolevels = &undolevels") end)
    perform("reset_hunk", 8)
    equal(git.text(buf), original:gsub("line 20\n", "keep this\n"))
    equal(index(repo, path), original)
    equal(table.concat(vim.fn.readfile(repo .. "/" .. path), "\n") .. "\n", original)
    vim.cmd.undo()
    equal(git.text(buf), working)
  end)

  test("insertions and deletions at both file boundaries stage and reset", function()
    for _, working in ipairs({ "first\none\ntwo\nthree\n", "one\ntwo\nthree\nlast\n", "two\nthree\n", "one\ntwo\n", "" }) do
      local original = "one\ntwo\nthree\n"
      local repo, buf, path = setup(original)
      set_text(buf, working)
      refresh(buf)
      local line = hunks.get_hunks(buf)[1].start
      perform("stage_hunk", line)
      equal(index(repo, path), working)
      perform("unstage_hunk", math.min(line, api.nvim_buf_line_count(buf)))
      equal(index(repo, path), original)
      perform("reset_hunk", math.min(line, api.nvim_buf_line_count(buf)))
      equal(git.text(buf), original)
    end
  end)

  test("missing final newlines are preserved when staging and unstaging", function()
    for _, case in ipairs({
      { "one\ntwo\n", "one\ntwo" },
      { "one\ntwo", "one\nchanged" },
      { "one\ntwo", "one\ntwo\n" },
    }) do
      local repo, buf, path = setup(case[1])
      set_text(buf, case[2])
      refresh(buf)
      perform("stage_hunk", 2)
      equal(index(repo, path), case[2])
      perform("unstage_hunk", 2)
      equal(index(repo, path), case[1])
      perform("reset_hunk", 2)
      equal(git.text(buf), case[1])
    end
  end)

  test("reset preserves no-EOL metadata on save and across undo", function()
    local original = "one\ntwo"
    local repo, buf, path = setup(original)
    local working = "one\nchanged\n"
    set_text(buf, working)
    refresh(buf)
    api.nvim_buf_call(buf, function() vim.cmd("let &undolevels = &undolevels") end)
    perform("reset_file", 1)
    equal(git.text(buf), original)
    equal(vim.bo[buf].endofline, false)
    equal(vim.bo[buf].fixendofline, false)
    vim.cmd.write()
    equal(read(repo .. "/" .. path), original)
    vim.cmd.undo()
    wait_for(function()
      return vim.bo[buf].endofline and vim.bo[buf].fixendofline
    end)
    equal(git.text(buf), working)

    local bom = "\239\187\191"
    repo, buf, path = setup(bom .. "one\nchanged\n")
    set_text(buf, "one\nworking\n")
    vim.bo[buf].bomb = false
    refresh(buf)
    api.nvim_buf_call(buf, function() vim.cmd("let &undolevels = &undolevels") end)
    perform("reset_file", 1)
    equal(vim.bo[buf].bomb, true)
    vim.cmd.undo()
    wait_for(function() return vim.bo[buf].bomb == false end)
    equal(git.text(buf), "one\nworking\n")
  end)

  test("CRLF index blobs retain their line endings", function()
    local repo, buf, path = setup("one\r\ntwo\r\n")
    equal(vim.bo[buf].fileformat, "dos")
    set_text(buf, "one\nchanged\n")
    refresh(buf)
    perform("stage_hunk", 2)
    equal(index(repo, path), "one\r\nchanged\r\n")
    perform("unstage_hunk", 2)
    equal(index(repo, path), "one\r\ntwo\r\n")
  end)

  test("UTF-8 BOMs do not create false hunks or change during actions", function()
    local bom = "\239\187\191"
    local repo, buf, path = setup(bom .. "one\ntwo\n")
    equal(vim.bo[buf].bomb, true)
    equal(#hunks.get_hunks(buf), 0)
    set_text(buf, "one\nchanged\n")
    refresh(buf)
    perform("stage_hunk", 2)
    equal(index(repo, path), bom .. "one\nchanged\n")
    perform("unstage_hunk", 2)
    perform("reset_hunk", 2)
    equal(git.text(buf), bom .. "one\ntwo\n")
    equal(api.nvim_buf_get_lines(buf, 0, -1, false), { "one", "two" })
  end)

  test("untracked files in an unborn repository can stage and unstage", function()
    local repo, buf, path = setup("new file\n", nil, true)
    equal(#hunks.get_hunks(buf), 1)
    perform("stage_hunk", 1)
    equal(index(repo, path), "new file\n")
    perform("unstage_hunk", 1)
    equal(run(repo, { "ls-files", "--stage", "--", path }), "")
    equal(git.text(buf), "new file\n")
  end)

  test("navigation wraps through staged and unstaged hunks", function()
    local original = numbered()
    local repo, buf, path = setup(original)
    write(repo .. "/" .. path, original:gsub("line 5\n", "staged\n"))
    run(repo, { "add", "--", path })
    set_text(buf, original:gsub("line 5\n", "staged\n"):gsub("line 18\n", "unstaged\n"))
    refresh(buf)
    local calls, real_run = 0, git.run
    git.run = function(...)
      calls = calls + 1
      return real_run(...)
    end
    api.nvim_win_set_cursor(0, { 1, 0 })
    hunks.navigate(1)
    wait_for(function() return api.nvim_win_get_cursor(0)[1] == 5 end)
    hunks.navigate(1)
    wait_for(function() return api.nvim_win_get_cursor(0)[1] == 18 end)
    hunks.navigate(1)
    wait_for(function() return api.nvim_win_get_cursor(0)[1] == 5 end)
    hunks.navigate(-1)
    wait_for(function() return api.nvim_win_get_cursor(0)[1] == 18 end)
    git.run = real_run
    equal(calls, 0)
  end)

  test("hunk preview is cached, scoped, and does not move focus", function()
    local original = numbered()
    local _, buf = setup(original)
    local working = original:gsub("line 5\n", "changed five\n")
      :gsub("line 18\n", "changed eighteen\n")
    set_text(buf, working)
    refresh(buf)
    api.nvim_win_set_cursor(0, { 5, 0 })
    local source_win = api.nvim_get_current_win()
    local calls, real_run = 0, git.run
    git.run = function(...)
      calls = calls + 1
      return real_run(...)
    end
    local win, preview_buf = hunks.preview_hunk()
    git.run = real_run
    assert(win and preview_buf)
    equal(api.nvim_get_current_win(), source_win)
    local lines = table.concat(api.nvim_buf_get_lines(preview_buf, 0, -1, false), "\n")
    assert(lines:find("@@", 1, true))
    assert(lines:find("-line 5", 1, true))
    assert(lines:find("+changed five", 1, true))
    assert(not lines:find("line 18", 1, true))
    equal(calls, 0)
    api.nvim_win_close(win, true)

    set_text(buf, original:gsub("line 20\n", ""))
    refresh(buf)
    api.nvim_win_set_cursor(0, { hunks.get_hunks(buf)[1].start, 0 })
    win, preview_buf = hunks.preview_hunk()
    assert(win and preview_buf)
    lines = table.concat(api.nvim_buf_get_lines(preview_buf, 0, -1, false), "\n")
    assert(lines:find("-line 20", 1, true))
    api.nvim_win_close(win, true)
  end)

  test("worktrees resolve their own index instead of the main repository index", function()
    local original = numbered()
    local repo, _, path = setup(original)
    local worktree = repo .. " worktree"
    run(repo, { "worktree", "add", "--quiet", "-b", "test-worktree", worktree })
    vim.cmd.edit(vim.fn.fnameescape(worktree .. "/" .. path))
    local buf = api.nvim_get_current_buf()
    set_text(buf, original:gsub("line 9\n", "worktree edit\n"))
    refresh(buf)
    perform("stage_hunk", 9)
    equal(index(worktree, path), original:gsub("line 9\n", "worktree edit\n"))
    equal(index(repo, path), original)
  end)

  test("custom clean filters reject writes while preserving buffer and index", function()
    local repo, buf, path = setup("original\n", "file.txt")
    write(repo .. "/.gitattributes", "*.txt filter=test\n")
    set_text(buf, "edited\n")
    refresh(buf)
    assert(hunks.stage_hunk())
    wait_for(function() return #notices > 0 end)
    assert(notices[1]:find("filter attributes", 1, true), notices[1])
    equal(index(repo, path), "original\n")
    equal(git.text(buf), "edited\n")
  end)

  test("a concurrently changed index rejects the patch and retains external staging", function()
    local original = numbered()
    local repo, buf, path = setup(original)
    local working = original:gsub("line 7\n", "reviewed edit\n")
    set_text(buf, working)
    refresh(buf)
    local real_run = git.run
    local external = original:gsub("line 20\n", "external staging\n")
    git.run = function(directory, arguments, options, callback)
      if arguments[1] == "apply" then
        write(repo .. "/" .. path, external)
        run(repo, { "add", "--", path })
      end
      return real_run(directory, arguments, options, callback)
    end
    api.nvim_win_set_cursor(0, { 7, 0 })
    assert(hunks.stage_hunk())
    wait_for(function() return #notices > 0 end)
    git.run = real_run
    assert(notices[1]:find("Could not stage hunk", 1, true), notices[1])
    equal(index(repo, path), external)
    equal(git.text(buf), working)
  end)

  test("unmerged entries refuse hunk actions without changing the index", function()
    local repo, _, path = setup("original\n", "file.txt")
    local oid = vim.trim(run(repo, { "rev-parse", "HEAD:" .. path }))
    local stages = "0 " .. string.rep("0", #oid) .. "\t" .. path .. "\n"
    for stage = 1, 3 do
      stages = stages .. "100644 " .. oid .. " " .. stage .. "\t" .. path .. "\n"
    end
    run(repo, { "update-index", "--index-info" }, { stdin = stages })
    local before = run(repo, { "ls-files", "--stage" })
    assert(hunks.stage_hunk())
    wait_for(function() return #notices > 0 end)
    assert(notices[1]:find("conflicts", 1, true), notices[1])
    equal(run(repo, { "ls-files", "--stage" }), before)
  end)

  test("Git index notifications refresh externally staged hunks", function()
    local original = numbered()
    local repo, buf, path = setup(original)
    write(repo .. "/" .. path, original:gsub("line 10\n", "external edit\n"))
    run(repo, { "add", "--", path })
    wait_for(function() return #hunks.get_hunks(buf, true) == 1 end)
    equal(hunks.get_hunks(buf, true)[1].start, 10)
  end)

  test("stale reads cannot decorate a renamed or edited buffer", function()
    local _, buf = setup("original\n")
    set_text(buf, "edited\n")
    local finished, failure
    hunks.refresh(buf, function(message)
      failure, finished = message, true
    end)
    set_text(buf, "newer edit\n")
    wait_for(function() return finished end)
    assert(failure and failure:find("buffer changed", 1, true), failure)
    refresh(buf)
    equal(#hunks.get_hunks(buf), 1)
    hunks.setup({ enabled = false })
    api.nvim_buf_delete(buf, { force = true })
  end)

  test("visual ranges stage and unstage only selected changed lines", function()
    local original = numbered()
    local repo, buf, path = setup(original)
    local working = original:gsub("line 3\n", "changed three\n")
      :gsub("line 12\n", "changed twelve\n")
      :gsub("line 20\n", "")
    set_text(buf, working)
    refresh(buf)
    perform("stage_hunk", { 2, 12 })
    local expected = original:gsub("line 3\n", "changed three\n")
      :gsub("line 12\n", "changed twelve\n")
    equal(index(repo, path), expected)
    equal(git.text(buf), working)
    equal(table.concat(vim.fn.readfile(repo .. "/" .. path), "\n") .. "\n", original)
    perform("unstage_hunk", { 3, 12 })
    equal(index(repo, path), original)
    equal(git.text(buf), working)
  end)

  test("partial addition ranges do not expand to the surrounding change", function()
    local original = numbered()
    local repo, buf, path = setup(original)
    local working = original:gsub("line 12\n", "changed twelve\nadded twelve\n")
    set_text(buf, working)
    refresh(buf)
    equal(hunks.get_hunks(buf)[1].new_count, 2)
    perform("stage_hunk", { 13, 13 })
    local expected = original:gsub("line 12\n", "line 12\nadded twelve\n")
    equal(index(repo, path), expected)
    equal(git.text(buf), working)
    perform("unstage_hunk", { 13, 13 })
    equal(index(repo, path), original)
    equal(git.text(buf), working)
  end)

  test("partial replacement ranges pair only selected lines while full ranges include the hunk", function()
    local original = numbered()
    local repo, buf, path = setup(original)
    local working = original:gsub("line 10\nline 11\nline 12\nline 13\n", "new ten\nnew eleven\n")
    set_text(buf, working)
    refresh(buf)
    local hunk = hunks.get_hunks(buf)[1]
    equal(hunk.old_count, 4)
    equal(hunk.new_count, 2)

    perform("stage_hunk", { 10, 10 })
    local selected = original:gsub("line 10\n", "new ten\n")
    equal(index(repo, path), selected)
    equal(git.text(buf), working)
    perform("unstage_hunk", { 10, 10 })
    equal(index(repo, path), original)

    perform("stage_hunk", { 10, 11 })
    local complete = original:gsub("line 10\nline 11\nline 12\nline 13\n", "new ten\nnew eleven\n")
    equal(index(repo, path), complete)
    perform("unstage_hunk", { 10, 11 })
    equal(index(repo, path), original)
    equal(git.text(buf), working)
  end)

  test("unstage ranges follow unstaged insertions above staged lines", function()
    local original = numbered()
    local repo, buf, path = setup(original)
    local staged = original:gsub("line 12\n", "staged twelve\n")
    write(repo .. "/" .. path, staged)
    run(repo, { "add", "--", path })
    local working = "new first\nnew second\n" .. staged
    set_text(buf, working)
    refresh(buf)
    perform("unstage_hunk", { 14, 14 })
    equal(index(repo, path), original)
    equal(git.text(buf), working)
  end)

  test("visual reset is limited to the range and is one undo step", function()
    local original = numbered()
    local _, buf = setup(original)
    local working = original:gsub("line 3\n", "changed three\n")
      :gsub("line 12\n", "changed twelve\n")
    set_text(buf, working)
    refresh(buf)
    api.nvim_buf_call(buf, function() vim.cmd("let &undolevels = &undolevels") end)
    perform("reset_hunk", { 3, 12 })
    equal(git.text(buf), original)
    vim.cmd.undo()
    equal(git.text(buf), working)
  end)

  test("visual mappings operate on the selected buffer range", function()
    local original = numbered()
    local repo, buf, path = setup(original)
    local working = original:gsub("line 4\n", "mapped four\n")
      :gsub("line 10\n", "mapped ten\n")
    set_text(buf, working)
    refresh(buf)
    vim.keymap.set("x", "<F5>", function()
      assert(hunks.stage_hunk())
    end, { buffer = buf, desc = "Stage selected hunks" })
    api.nvim_win_set_cursor(0, { 4, 0 })
    api.nvim_feedkeys(api.nvim_replace_termcodes("V6j<F5>", true, false, true), "xt", false)
    wait_for(function()
      return index(repo, path):find("mapped ten", 1, true) ~= nil
    end)
    local expected = original:gsub("line 4\n", "mapped four\n")
      :gsub("line 10\n", "mapped ten\n")
    equal(index(repo, path), expected)
    equal(api.nvim_get_mode().mode, "n")
  end)

  test("blockwise visual mappings operate on all selected buffer lines", function()
    local original = numbered()
    local repo, buf, path = setup(original)
    local working = original:gsub("line 4\n", "mapped four\n")
      :gsub("line 10\n", "mapped ten\n")
    set_text(buf, working)
    refresh(buf)
    vim.keymap.set("x", "<F5>", function()
      assert(hunks.stage_hunk())
    end, { buffer = buf, desc = "Stage selected hunks" })
    api.nvim_win_set_cursor(0, { 4, 0 })
    api.nvim_feedkeys(api.nvim_replace_termcodes("<C-v>6j<F5>", true, false, true), "xt", false)
    wait_for(function()
      local staged = index(repo, path)
      return staged:find("mapped four", 1, true) ~= nil and staged:find("mapped ten", 1, true) ~= nil
    end)
    equal(index(repo, path), working)
    equal(api.nvim_get_mode().mode, "n")
  end)

  test("hunk text object works visually and with an operator", function()
    local original = numbered()
    local _, buf = setup(original)
    local working = original:gsub("line 12\nline 13\n", "changed twelve\nchanged thirteen\n")
    set_text(buf, working)
    refresh(buf)
    vim.keymap.set({ "x", "o" }, "ih", function()
      return hunks.select_hunk()
    end, { buffer = buf, desc = "Select Git hunk" })
    api.nvim_win_set_cursor(0, { 12, 0 })
    vim.fn.setreg('"', "")
    api.nvim_feedkeys(api.nvim_replace_termcodes("vihy", true, false, true), "xt", false)
    equal(vim.fn.getreg('"'), "changed twelve\nchanged thirteen\n")
    api.nvim_win_set_cursor(0, { 12, 0 })
    vim.fn.setreg('"', "")
    api.nvim_feedkeys(api.nvim_replace_termcodes("yih", true, false, true), "xt", false)
    equal(vim.fn.getreg('"'), "changed twelve\nchanged thirteen\n")
    api.nvim_win_set_cursor(0, { 12, 0 })
    api.nvim_feedkeys(api.nvim_replace_termcodes("dih", true, false, true), "xt", false)
    equal(api.nvim_buf_get_lines(buf, 11, 13, false), { "line 14", "line 15" })
  end)

  test("hunk text object refreshes a stale cache and supports change", function()
    local original = numbered()
    local _, buf = setup(original)
    hunks.setup({ debounce = 10000 })
    set_text(buf, original:gsub("line 12\nline 13\n", "changed twelve\nchanged thirteen\n"))
    vim.keymap.set({ "x", "o" }, "ih", function()
      return hunks.select_hunk()
    end, { buffer = buf, desc = "Select Git hunk" })
    api.nvim_win_set_cursor(0, { 12, 0 })
    vim.fn.setreg('"', "")
    api.nvim_feedkeys(api.nvim_replace_termcodes("yih", true, false, true), "xt", false)
    equal(vim.fn.getreg('"'), "changed twelve\nchanged thirteen\n")
    api.nvim_feedkeys(api.nvim_replace_termcodes("cihreplacement\27", true, false, true), "xt", false)
    equal(api.nvim_buf_get_lines(buf, 11, 13, false), { "replacement", "line 14" })
  end)

  test("a staged hunk covered by an unstaged deletion cannot select an adjacent line", function()
    local original = numbered()
    local repo, buf, path = setup(original)
    local staged = original:gsub("line 12\n", "staged twelve\n")
    write(repo .. "/" .. path, staged)
    run(repo, { "add", "--", path })
    local working = staged:gsub("staged twelve\n", "")
    set_text(buf, working)
    refresh(buf)
    local hunk = hunks.get_hunks(buf)[1]
    equal(hunk.type, "delete")
    vim.keymap.set({ "x", "o" }, "ih", function()
      return hunks.select_hunk()
    end, { buffer = buf, desc = "Select Git hunk" })
    api.nvim_win_set_cursor(0, { hunk.start, 0 })
    api.nvim_feedkeys(api.nvim_replace_termcodes("dih", true, false, true), "xt", false)
    equal(git.text(buf), working)
    assert(notices[#notices]:find("Deletion-only", 1, true), vim.inspect(notices))
  end)

  test("deletion-only hunks cannot be selected as destructive text", function()
    local original = numbered()
    local _, buf = setup(original)
    set_text(buf, original:gsub("line 12\n", ""))
    refresh(buf)
    local hunk = hunks.get_hunks(buf)[1]
    equal(hunk.type, "delete")
    vim.keymap.set({ "x", "o" }, "ih", function()
      return hunks.select_hunk()
    end, { buffer = buf, desc = "Select Git hunk" })
    api.nvim_win_set_cursor(0, { hunk.start, 0 })
    api.nvim_feedkeys(api.nvim_replace_termcodes("dih", true, false, true), "xt", false)
    equal(git.text(buf), original:gsub("line 12\n", ""))
    assert(notices[#notices]:find("Deletion-only", 1, true), vim.inspect(notices))
  end)

  test("ambiguous unstage ranges are rejected without touching the index", function()
    local original = "one\ntwo\nthree\nfour\nfive\n"
    local repo, buf, path = setup(original)
    local staged = original:gsub("four\n", "staged four\n")
    write(repo .. "/" .. path, staged)
    run(repo, { "add", "--", path })
    local working = staged:gsub("two\n", "")
    set_text(buf, working)
    refresh(buf)
    assert(hunks.unstage_hunk({ 1, 2 }))
    wait_for(function() return #notices > 0 end)
    equal(index(repo, path), staged)
    equal(git.text(buf), working)
    assert(notices[1] and notices[1]:find("unstaged deleted", 1, true), vim.inspect(notices))
  end)

  test("whole-file actions stage, unstage and reset one file only", function()
    local original = numbered()
    local repo, buf, path = setup(original)
    write(repo .. "/other.txt", "other staged\n")
    run(repo, { "add", "--", "other.txt" })
    local working = original:gsub("line 3\n", "whole three\n")
      :gsub("line 18\n", "whole eighteen\n")
    set_text(buf, working)
    refresh(buf)
    perform("stage_file", 1)
    equal(index(repo, path), working)
    equal(index(repo, "other.txt"), "other staged\n")
    equal(table.concat(vim.fn.readfile(repo .. "/" .. path), "\n") .. "\n", original)
    perform("unstage_file", 1)
    equal(index(repo, path), original)
    equal(index(repo, "other.txt"), "other staged\n")
    equal(git.text(buf), working)
    api.nvim_buf_call(buf, function() vim.cmd("let &undolevels = &undolevels") end)
    perform("reset_file", 1)
    equal(git.text(buf), original)
    equal(index(repo, path), original)
    vim.cmd.undo()
    equal(git.text(buf), working)
  end)

  test("whole-file actions handle empty untracked, BOM and CRLF files", function()
    local repo, buf, path = setup("", nil, true)
    perform("stage_file", 1)
    assert(run(repo, { "ls-files", "--stage", "--", path }) ~= "")
    equal(index(repo, path), "")
    perform("unstage_file", 1)
    equal(run(repo, { "ls-files", "--stage", "--", path }), "")

    local bom = "\239\187\191"
    repo, buf, path = setup(bom .. "one\r\ntwo\r\n")
    set_text(buf, "one\nchanged\n")
    refresh(buf)
    perform("stage_file", 1)
    equal(index(repo, path), bom .. "one\r\nchanged\r\n")
    perform("unstage_file", 1)
    equal(index(repo, path), bom .. "one\r\ntwo\r\n")
    perform("reset_file", 1)
    equal(git.text(buf), bom .. "one\ntwo\n")
    equal(vim.bo[buf].bomb, true)
    equal(vim.bo[buf].fileformat, "dos")
  end)

  test("whole-file actions refuse unmerged entries", function()
    local repo, buf, path = setup("original\n", "file.txt")
    local oid = vim.trim(run(repo, { "rev-parse", "HEAD:" .. path }))
    local stages = "0 " .. string.rep("0", #oid) .. "\t" .. path .. "\n"
    for stage = 1, 3 do
      stages = stages .. "100644 " .. oid .. " " .. stage .. "\t" .. path .. "\n"
    end
    run(repo, { "update-index", "--index-info" }, { stdin = stages })
    local before = run(repo, { "ls-files", "--stage" })
    for _, method in ipairs({ "stage_file", "unstage_file", "reset_file" }) do
      notices = {}
      assert(hunks[method]())
      wait_for(function() return #notices > 0 end)
      assert(notices[1]:find("conflicts", 1, true), notices[1])
      equal(run(repo, { "ls-files", "--stage" }), before)
      equal(git.text(buf), "original\n")
    end
  end)
end, debug.traceback)

hunks.setup({ enabled = false })
vim.fn.delete(temp, "rf")
if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
end
print("Passed " .. passed .. " hunk tests")
vim.cmd("qa!")
