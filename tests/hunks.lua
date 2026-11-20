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

  test("ignore rules remove existing signs and are rechecked on editor refreshes", function()
    local repo, buf = setup("local configuration\n", ".env.development", true)
    local namespace = api.nvim_create_namespace("igit.hunks")
    equal(#hunks.get_hunks(buf), 1)
    equal(#api.nvim_buf_get_extmarks(buf, namespace, 0, -1, {}), 1)
    write(repo .. "/.gitignore", ".env.*\n")
    api.nvim_exec_autocmds("BufEnter", { buffer = buf })
    wait_for(function()
      return #api.nvim_buf_get_extmarks(buf, namespace, 0, -1, {}) == 0
    end)
    equal(hunks.get_hunks(buf), {})
    equal(hunks.get_hunks(buf, true), {})
    equal(git.text(buf), "local configuration\n")
    equal(notices, {})

    write(repo .. "/.gitignore", ".env.*\n!.env.development\n")
    api.nvim_exec_autocmds("FocusGained", {})
    wait_for(function() return #hunks.get_hunks(buf) == 1 end)
    equal(hunks.get_hunks(buf)[1].type, "add")
    equal(#api.nvim_buf_get_extmarks(buf, namespace, 0, -1, {}), 1)
  end)

  test("Git ignore sources suppress additions for untracked files", function()
    for _, source in ipairs({ "root", "nested", "directory", "exclude", "global" }) do
      local repo = setup("tracked\n")
      local directory = repo .. "/nested 中文"
      vim.fn.mkdir(directory, "p")
      local name = ".env development ; $literal[1].txt"
      local path = "nested 中文/" .. name
      if source == "root" then
        write(repo .. "/.gitignore", "nested 中文/.env*\n")
      elseif source == "nested" then
        write(directory .. "/.gitignore", ".env*\n")
      elseif source == "directory" then
        write(repo .. "/.gitignore", "nested 中文/\n")
      elseif source == "exclude" then
        write(repo .. "/.git/info/exclude", ".env*\n")
      else
        local excludes = repo .. "/global excludes"
        write(excludes, ".env*\n")
        run(repo, { "config", "core.excludesFile", excludes })
      end
      write(repo .. "/" .. path, "local configuration\n")
      vim.cmd.edit(vim.fn.fnameescape(repo .. "/" .. path))
      local buf = api.nvim_get_current_buf()
      refresh(buf)
      equal(hunks.get_hunks(buf), {})
      equal(hunks.get_hunks(buf, true), {})
      equal(api.nvim_buf_get_extmarks(buf, api.nvim_create_namespace("igit.hunks"), 0, -1, {}), {})
      equal(git.text(buf), "local configuration\n")
      equal(notices, {})
    end
  end)

  test("ignored files reject hunk and whole-file actions without changing data", function()
    local repo, buf, path = setup("local configuration\n", ".env.development", true)
    write(repo .. "/.gitignore", ".env.*\n")
    write(repo .. "/other.txt", "other staged\n")
    run(repo, { "add", "--", "other.txt" })
    set_text(buf, "unsaved local configuration\n")
    refresh(buf)
    local before = run(repo, { "ls-files", "--stage" })
    for _, method in ipairs({ "stage_hunk", "unstage_hunk", "reset_hunk", "stage_file", "unstage_file", "reset_file" }) do
      notices = {}
      assert(hunks[method]())
      wait_for(function() return #notices > 0 end)
      assert(notices[1]:find("ignored", 1, true), notices[1])
      equal(run(repo, { "ls-files", "--stage" }), before)
      equal(git.text(buf), "unsaved local configuration\n")
      equal(read(repo .. "/" .. path), "local configuration\n")
    end
  end)

  test("tracked and force-added files retain hunks when ignore patterns match", function()
    local repo, buf, path = setup("original\n", ".env.development")
    write(repo .. "/.gitignore", ".env.*\n")
    write(repo .. "/" .. path, "staged\n")
    run(repo, { "add", "--", path })
    set_text(buf, "unsaved\n")
    refresh(buf)
    equal(#hunks.get_hunks(buf), 1)
    equal(#hunks.get_hunks(buf, true), 1)
    perform("stage_hunk", 1)
    equal(index(repo, path), "unsaved\n")

    repo, buf, path = setup("new configuration\n", ".env.development", true)
    write(repo .. "/.gitignore", ".env.*\n")
    run(repo, { "add", "--force", "--", path })
    set_text(buf, "unsaved configuration\n")
    refresh(buf)
    equal(#hunks.get_hunks(buf), 1)
    equal(#hunks.get_hunks(buf, true), 1)
    perform("stage_file", 1)
    equal(index(repo, path), "unsaved configuration\n")
  end)

  test("staged deletions retain hunks when the remaining file matches ignore rules", function()
    local repo, buf, path = setup("original\n", ".env.development")
    write(repo .. "/.gitignore", ".env.*\n")
    run(repo, { "update-index", "--force-remove", "--", path })
    refresh(buf)
    equal(#hunks.get_hunks(buf), 1)
    equal(#hunks.get_hunks(buf, true), 1)
    equal(hunks.get_hunks(buf, true)[1].type, "delete")
    perform("unstage_file", 1)
    equal(index(repo, path), "original\n")
    equal(git.text(buf), "original\n")
  end)

  test("failed ignore checks clear obsolete signs without treating errors as additions", function()
    local repo, buf, path = setup("new configuration\n", ".env.development", true)
    equal(#hunks.get_hunks(buf), 1)
    local real_run = git.run
    git.run = function(directory, arguments, options, callback)
      if vim.tbl_contains(arguments, "check-ignore") then
        vim.schedule(function()
          callback({ code = 128, stdout = "", stderr = "Ignore check failed\n" })
        end)
        return
      end
      return real_run(directory, arguments, options, callback)
    end
    local finished, failure
    hunks.refresh(buf, function(message)
      failure, finished = message, true
    end)
    local completed = vim.wait(5000, function() return finished end, 10)
    git.run = real_run
    assert(completed, "Ignore check did not complete")
    equal(failure, "Ignore check failed")
    equal(hunks.get_hunks(buf), {})
    equal(api.nvim_buf_get_extmarks(buf, api.nvim_create_namespace("igit.hunks"), 0, -1, {}), {})
    equal(run(repo, { "ls-files", "--stage", "--", path }), "")
    equal(git.text(buf), "new configuration\n")
    equal(read(repo .. "/" .. path), "new configuration\n")
    refresh(buf)
    equal(#hunks.get_hunks(buf), 1)
    equal(notices, {})
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

  test("explicit previews distinguish HEAD, index and buffer at the same line", function()
    local repo, buf, path = setup("HEAD text\n")
    write(repo .. "/" .. path, "index text\n")
    run(repo, { "add", "--", path })
    set_text(buf, "buffer text\n")
    refresh(buf)
    local source = api.nvim_get_current_win()
    local win, preview_buf = hunks.preview_hunk("staged")
    assert(win and preview_buf)
    local text = table.concat(api.nvim_buf_get_lines(preview_buf, 0, -1, false), "\n")
    assert(text:find("-HEAD text", 1, true), text)
    assert(text:find("+index text", 1, true), text)
    assert(not text:find("buffer text", 1, true), text)
    equal(api.nvim_get_current_win(), source)
    equal(api.nvim_win_get_config(win).title[1][1], " IGit Staged Hunk ")
    api.nvim_set_current_win(win)
    api.nvim_feedkeys("s", "xt", false)
    local current = api.nvim_get_current_buf()
    text = table.concat(api.nvim_buf_get_lines(current, 0, -1, false), "\n")
    assert(text:find("-index text", 1, true), text)
    assert(text:find("+buffer text", 1, true), text)
    equal(api.nvim_win_get_config(0).title[1][1], " IGit Unstaged Hunk ")
    api.nvim_win_close(api.nvim_get_current_win(), true)
    equal(index(repo, path), "index text\n")
    equal(git.text(buf), "buffer text\n")
  end)

  test("navigation filters staged and unstaged positions independently", function()
    local original = numbered()
    local repo, buf, path = setup(original)
    local staged = original:gsub("line 5\n", "staged five\n"):gsub("line 12\n", "staged twelve\n")
    write(repo .. "/" .. path, staged)
    run(repo, { "add", "--", path })
    set_text(buf, staged:gsub("line 18\n", "unstaged eighteen\n"))
    refresh(buf)
    api.nvim_win_set_cursor(0, { 1, 0 })
    hunks.navigate(1, "unstaged")
    equal(api.nvim_win_get_cursor(0)[1], 18)
    hunks.navigate(1, "staged")
    equal(api.nvim_win_get_cursor(0)[1], 5)
    hunks.navigate(-1, "staged")
    equal(api.nvim_win_get_cursor(0)[1], 12)
    hunks.navigate(1, "unstaged")
    equal(api.nvim_win_get_cursor(0)[1], 18)
  end)

  test("Undo Stage restores previous staging and preserves later sibling staging", function()
    local repo, buf, path = setup("HEAD text\n")
    write(repo .. "/" .. path, "already staged\n")
    run(repo, { "add", "--", path })
    set_text(buf, "unsaved text\n")
    refresh(buf)
    perform("stage_hunk", 1)
    equal(index(repo, path), "unsaved text\n")
    write(repo .. "/other.txt", "later sibling staging\n")
    run(repo, { "add", "--", "other.txt" })
    perform("undo_stage", 1)
    equal(index(repo, path), "already staged\n")
    equal(index(repo, "other.txt"), "later sibling staging\n")
    equal(git.text(buf), "unsaved text\n")
    equal(read(repo .. "/" .. path), "already staged\n")
  end)

  test("Undo Stage covers stage and unstage for cursor hunks, ranges and files", function()
    for _, operation in ipairs({
      { "stage_hunk", 12 }, { "stage_hunk", { 12, 12 } }, { "stage_file", 1 },
      { "unstage_hunk", 2 }, { "unstage_hunk", { 2, 2 } }, { "unstage_file", 1 },
    }) do
      local original = numbered()
      local repo, buf, path = setup(original)
      local staged = original:gsub("line 2\n", "existing staged\n")
      write(repo .. "/" .. path, staged)
      run(repo, { "add", "--", path })
      local working = staged:gsub("line 12\n", "unsaved twelve\n")
      set_text(buf, working)
      refresh(buf)
      perform(operation[1], operation[2])
      assert(index(repo, path) ~= staged)
      perform("undo_stage", 1)
      equal(index(repo, path), staged)
      equal(git.text(buf), working)
      equal(read(repo .. "/" .. path), staged)
    end
  end)

  test("successive Undo Stage actions restore index history independently of buffer undo", function()
    local original = numbered()
    local repo, buf, path = setup(original)
    local working = original:gsub("line 5\n", "first staging\n"):gsub("line 18\n", "second staging\n")
    set_text(buf, working)
    refresh(buf)
    perform("stage_hunk", 5)
    perform("stage_hunk", 18)
    set_text(buf, working .. "newer unsaved text")
    vim.bo[buf].fixendofline = false
    perform("undo_stage", 1)
    equal(index(repo, path), original:gsub("line 5\n", "first staging\n"))
    perform("undo_stage", 1)
    equal(index(repo, path), original)
    equal(git.text(buf), working .. "newer unsaved text")
    equal(vim.bo[buf].endofline, false)
    equal(vim.bo[buf].fixendofline, false)
  end)

  test("Undo Stage restores absent and empty entries and executable modes exactly", function()
    for _, text in ipairs({ "", "new content\n" }) do
      local repo, buf, path = setup(text, nil, true)
      assert(vim.fn.setfperm(repo .. "/" .. path, "rwxr-xr-x") == 1)
      perform("stage_file", 1)
      local entry = run(repo, { "ls-files", "--stage", "-z", "--", path })
      assert(entry:find("^100755 "), entry)
      perform("undo_stage", 1)
      equal(run(repo, { "ls-files", "--stage", "-z", "--", path }), "")
      perform("stage_file", 1)
      perform("unstage_file", 1)
      equal(run(repo, { "ls-files", "--stage", "-z", "--", path }), "")
      perform("undo_stage", 1)
      equal(run(repo, { "ls-files", "--stage", "-z", "--", path }), entry)
      equal(git.text(buf), text)
      equal(read(repo .. "/" .. path), text)
    end
  end)

  test("stale Undo Stage refuses external index changes and retains its record for retry", function()
    local repo, buf, path = setup("original\n")
    set_text(buf, "staged by plugin\n")
    refresh(buf)
    perform("stage_file", 1)
    local expected = run(repo, { "ls-files", "--stage", "-z", "--", path })
    write(repo .. "/" .. path, "externally staged\n")
    write(repo .. "/other.txt", "later sibling\n")
    run(repo, { "add", "--", path, "other.txt" })
    local before = run(repo, { "ls-files", "--stage", "-z" })
    assert(hunks.undo_stage())
    wait_for(function() return #notices > 0 end)
    assert(notices[1]:find("index entry changed", 1, true), notices[1])
    equal(run(repo, { "ls-files", "--stage", "-z" }), before)
    equal(git.text(buf), "staged by plugin\n")
    equal(vim.fn.filereadable(repo .. "/.git/index.lock"), 0)
    run(repo, { "update-index", "-z", "--index-info" }, { stdin = expected })
    notices = {}
    perform("undo_stage", 1)
    equal(index(repo, path), "original\n")
    equal(index(repo, "other.txt"), "later sibling\n")
  end)

  for _, variant in ipairs({
    { name = "skip-worktree", flags = { "--skip-worktree" }, marker = "S" },
    { name = "combined", flags = { "--assume-unchanged", "--skip-worktree" }, marker = "s" },
  }) do
    test(variant.name .. " index flags survive stage, unstage and Undo Stage", function()
      local repo, buf, path = setup("original\n")
      for _, flag in ipairs(variant.flags) do
        run(repo, { "update-index", flag, "--", path })
      end
      set_text(buf, "staged edit\n")
      refresh(buf)
      perform("stage_file", 1)
      equal(run(repo, { "ls-files", "-v", "--", path }):sub(1, 1), variant.marker)
      perform("undo_stage", 1)
      equal(index(repo, path), "original\n")
      equal(run(repo, { "ls-files", "-v", "--", path }):sub(1, 1), variant.marker)
      perform("stage_file", 1)
      perform("unstage_file", 1)
      equal(index(repo, path), "original\n")
      equal(run(repo, { "ls-files", "-v", "--", path }):sub(1, 1), variant.marker)
      perform("undo_stage", 1)
      equal(index(repo, path), "staged edit\n")
      equal(run(repo, { "ls-files", "-v", "--", path }):sub(1, 1), variant.marker)
      equal(git.text(buf), "staged edit\n")
      equal(read(repo .. "/" .. path), "original\n")
    end)
  end

  test("flag restoration is verified before publishing the private index", function()
    local repo, buf, path = setup("original\n")
    run(repo, { "update-index", "--skip-worktree", "--", path })
    local before = read(repo .. "/.git/index")
    set_text(buf, "staged edit\n")
    refresh(buf)
    local real_run, intercepted = git.run, false
    git.run = function(directory, arguments, options, callback)
      if arguments[1] == "update-index" and vim.tbl_contains(arguments, "--skip-worktree") then
        intercepted = true
        vim.schedule(function() callback({ code = 0, stdout = "", stderr = "" }) end)
        return
      end
      return real_run(directory, arguments, options, callback)
    end
    assert(hunks.stage_file())
    wait_for(function() return #notices > 0 end)
    git.run = real_run
    assert(intercepted)
    assert(notices[1]:find("index flags", 1, true), notices[1])
    equal(read(repo .. "/.git/index"), before)
    equal(index(repo, path), "original\n")
    equal(git.text(buf), "staged edit\n")
    equal(vim.fn.filereadable(repo .. "/.git/index.lock"), 0)
    notices = {}
    perform("stage_file", 1)
    equal(run(repo, { "ls-files", "-v", "--", path }):sub(1, 1), "S")
  end)

  test("Undo Stage refuses pruned blobs without changing the index and retains history", function()
    local repo, buf, path = setup("original\n")
    local staged = "previous staging without a commit\n"
    write(repo .. "/" .. path, staged)
    run(repo, { "add", "--", path })
    local oid = vim.trim(run(repo, { "rev-parse", ":" .. path }))
    set_text(buf, "staged by plugin\n")
    refresh(buf)
    perform("stage_file", 1)
    write(repo .. "/other.txt", "later sibling\n")
    run(repo, { "add", "--", "other.txt" })
    run(repo, { "gc", "--prune=now" })
    local missing = vim.system({ "git", "-C", repo, "cat-file", "-e", oid }, { text = false }):wait()
    assert(missing.code ~= 0, "The previous staged blob was not pruned")
    local before = read(repo .. "/.git/index")
    assert(hunks.undo_stage())
    wait_for(function() return #notices > 0 end)
    assert(notices[1]:find("previous staged blob", 1, true), notices[1])
    equal(read(repo .. "/.git/index"), before)
    equal(index(repo, path), "staged by plugin\n")
    equal(index(repo, "other.txt"), "later sibling\n")
    equal(git.text(buf), "staged by plugin\n")
    equal(read(repo .. "/" .. path), staged)
    equal(vim.fn.filereadable(repo .. "/.git/index.lock"), 0)
    equal(vim.trim(run(repo, { "hash-object", "-w", "--stdin" }, { stdin = staged })), oid)
    notices = {}
    perform("undo_stage", 1)
    equal(index(repo, path), staged)
    equal(index(repo, "other.txt"), "later sibling\n")
  end)

  for _, failure in ipairs({ "unexpected type", "unreadable content" }) do
    test("Undo Stage retains history when the previous blob has " .. failure, function()
      local repo, buf, path = setup("original\n")
      set_text(buf, "staged by plugin\n")
      refresh(buf)
      perform("stage_file", 1)
      write(repo .. "/other.txt", "later sibling\n")
      run(repo, { "add", "--", "other.txt" })
      local before = read(repo .. "/.git/index")
      local real_run, intercepted = git.run, false
      git.run = function(directory, arguments, options, callback)
        if options.env and options.env.GIT_INDEX_FILE and arguments[1] == "cat-file"
            and arguments[2] == (failure == "unexpected type" and "-t" or "blob") then
          intercepted = true
          vim.schedule(function()
            callback({
              code = failure == "unexpected type" and 0 or 128,
              stdout = failure == "unexpected type" and "tree\n" or "",
              stderr = failure == "unexpected type" and "" or "Unreadable object content",
            })
          end)
          return
        end
        return real_run(directory, arguments, options, callback)
      end
      assert(hunks.undo_stage())
      wait_for(function() return #notices > 0 end)
      git.run = real_run
      assert(intercepted)
      assert(notices[1]:find("previous staged blob", 1, true), notices[1])
      equal(read(repo .. "/.git/index"), before)
      equal(index(repo, path), "staged by plugin\n")
      equal(index(repo, "other.txt"), "later sibling\n")
      equal(git.text(buf), "staged by plugin\n")
      equal(vim.fn.filereadable(repo .. "/.git/index.lock"), 0)
      notices = {}
      perform("undo_stage", 1)
      equal(index(repo, path), "original\n")
      equal(index(repo, "other.txt"), "later sibling\n")
    end)
  end

  test("stage and unstage reject flag-only changes after capture", function()
    for _, method in ipairs({ "stage_file", "unstage_file" }) do
      local repo, buf, path = setup("original\n")
      write(repo .. "/" .. path, "already staged\n")
      run(repo, { "add", "--", path })
      set_text(buf, "reviewed edit\n")
      refresh(buf)
      local real_run = git.run
      git.run = function(directory, arguments, options, callback)
        if arguments[1] == "rev-parse" and vim.tbl_contains(arguments, "--git-path") then
          run(repo, { "update-index", "--skip-worktree", "--", path })
        end
        return real_run(directory, arguments, options, callback)
      end
      assert(hunks[method]())
      wait_for(function() return #notices > 0 end)
      git.run = real_run
      assert(notices[1]:find("index entry changed", 1, true), notices[1])
      equal(index(repo, path), "already staged\n")
      equal(index(repo, "other.txt"), "other original\n")
      equal(run(repo, { "ls-files", "-v", "--", path }):sub(1, 1), "S")
      equal(git.text(buf), "reviewed edit\n")
      equal(vim.fn.filereadable(repo .. "/.git/index.lock"), 0)
      notices = {}
      perform(method, 1)
    end
  end)

  test("index flags survive staging and undo and external flag changes are detected", function()
    local repo, buf, path = setup("original\n")
    run(repo, { "update-index", "--assume-unchanged", "--", path })
    set_text(buf, "staged edit\n")
    refresh(buf)
    perform("stage_file", 1)
    assert(run(repo, { "ls-files", "-v", "--", path }):sub(1, 1) == "h")
    perform("undo_stage", 1)
    equal(index(repo, path), "original\n")
    assert(run(repo, { "ls-files", "-v", "--", path }):sub(1, 1) == "h")
    run(repo, { "update-index", "--no-assume-unchanged", "--", path })
    perform("stage_file", 1)
    run(repo, { "update-index", "--skip-worktree", "--", path })
    assert(hunks.undo_stage())
    wait_for(function() return #notices > 0 end)
    assert(notices[1]:find("index entry changed", 1, true), notices[1])
    equal(index(repo, path), "staged edit\n")
    assert(run(repo, { "ls-files", "-v", "--", path }):sub(1, 1) == "S")
  end)

  test("Undo Stage respects an existing index lock without deleting it", function()
    local repo, buf, path = setup("original\n")
    set_text(buf, "staged edit\n")
    refresh(buf)
    perform("stage_file", 1)
    write(repo .. "/.git/index.lock", "another operation")
    assert(hunks.undo_stage())
    wait_for(function() return #notices > 0 end)
    assert(notices[1]:find("Could not lock the Git index", 1, true), notices[1])
    equal(read(repo .. "/.git/index.lock"), "another operation")
    equal(index(repo, path), "staged edit\n")
    assert(vim.uv.fs_unlink(repo .. "/.git/index.lock"))
    notices = {}
    perform("undo_stage", 1)
    equal(index(repo, path), "original\n")
  end)

  for _, failure in ipairs({ "failure", "timeout" }) do
    for _, operation in ipairs({ "stage_file", "undo_stage" }) do
      test(operation .. " child " .. failure .. " cleans owned locks and preserves existing locks", function()
        local repo, buf, path = setup("original\n")
        set_text(buf, "reviewed edit\n")
        refresh(buf)
        if operation == "undo_stage" then
          perform("stage_file", 1)
        end
        local before = read(repo .. "/.git/index")
        local external = repo .. "/.git/index.lock.lock"
        write(external, "another operation's nested lock")
        local real_run, candidate, child_result = git.run, nil, nil
        git.run = function(directory, arguments, options, callback)
          if operation == "stage_file" and arguments[1] == "apply"
              or operation == "undo_stage" and arguments[1] == "update-index"
              and vim.tbl_contains(arguments, "--index-info") then
            candidate = options.env.GIT_INDEX_FILE
            local child = { "sh", "-c", failure == "timeout"
              and 'printf owned > "$1.lock"; exec sleep 10'
              or 'printf owned > "$1.lock"; exit 7', "igit-test", candidate }
            return vim.system(child, { text = false, timeout = failure == "timeout" and 100 or nil }, function(result)
              child_result = result
              vim.schedule(function() callback(result) end)
            end)
          end
          return real_run(directory, arguments, options, callback)
        end
        assert(hunks[operation]())
        wait_for(function() return #notices > 0 end)
        git.run = real_run
        assert(child_result and child_result.code ~= 0)
        if failure == "timeout" then
          equal(child_result.code, 124)
        end
        assert(candidate)
        assert(candidate ~= repo .. "/.git/index.lock", "Child Git shares the real index lock pathname")
        equal(vim.uv.fs_stat(candidate), nil)
        equal(vim.uv.fs_stat(candidate .. ".lock"), nil)
        equal(vim.uv.fs_stat(vim.fs.dirname(candidate)), nil)
        equal(read(external), "another operation's nested lock")
        equal(vim.fn.filereadable(repo .. "/.git/index.lock"), 0)
        equal(read(repo .. "/.git/index"), before)
        equal(index(repo, path), operation == "undo_stage" and "reviewed edit\n" or "original\n")
        equal(index(repo, "other.txt"), "other original\n")
        equal(git.text(buf), "reviewed edit\n")
        notices = {}
        perform(operation, 1)
        if operation == "stage_file" then
          perform("undo_stage", 1)
        end
        equal(index(repo, path), "original\n")
        equal(read(external), "another operation's nested lock")
      end)
    end
  end

  test("Undo Stage publication failures retain history and clean transaction files", function()
    local repo, buf, path = setup("original\n")
    set_text(buf, "reviewed edit\n")
    refresh(buf)
    perform("stage_file", 1)
    write(repo .. "/other.txt", "later sibling\n")
    run(repo, { "add", "--", "other.txt" })
    local before = read(repo .. "/.git/index")
    local index_path = assert(vim.uv.fs_realpath(repo .. "/.git/index"))
    local real_rename, candidate = vim.uv.fs_rename, nil
    vim.uv.fs_rename = function(source, destination, ...)
      if vim.uv.fs_realpath(destination) == index_path then
        candidate = source
        return nil, "ENOSPC: no space left on device"
      end
      return real_rename(source, destination, ...)
    end
    assert(hunks.undo_stage())
    wait_for(function() return #notices > 0 end)
    vim.uv.fs_rename = real_rename
    assert(candidate)
    assert(notices[1]:find("Could not publish the Git index", 1, true), notices[1])
    equal(read(repo .. "/.git/index"), before)
    equal(index(repo, path), "reviewed edit\n")
    equal(index(repo, "other.txt"), "later sibling\n")
    equal(git.text(buf), "reviewed edit\n")
    equal(vim.uv.fs_stat(candidate), nil)
    equal(vim.uv.fs_stat(candidate .. ".lock"), nil)
    equal(vim.uv.fs_stat(vim.fs.dirname(candidate)), nil)
    equal(vim.fn.filereadable(repo .. "/.git/index.lock"), 0)
    notices = {}
    perform("undo_stage", 1)
    equal(index(repo, path), "original\n")
    equal(index(repo, "other.txt"), "later sibling\n")
  end)

  test("private index transactions preserve split-index entries", function()
    local repo, buf, path = setup("original\n")
    run(repo, { "update-index", "--split-index" })
    set_text(buf, "reviewed edit\n")
    refresh(buf)
    perform("stage_file", 1)
    equal(index(repo, path), "reviewed edit\n")
    equal(index(repo, "other.txt"), "other original\n")
    perform("undo_stage", 1)
    equal(index(repo, path), "original\n")
    equal(index(repo, "other.txt"), "other original\n")
  end)

  test("a stage transaction preserves sibling staging that changed after its snapshot", function()
    local repo, buf, path = setup("original\n")
    set_text(buf, "reviewed edit\n")
    refresh(buf)
    local real_run = git.run
    git.run = function(directory, arguments, options, callback)
      if arguments[1] == "rev-parse" and vim.tbl_contains(arguments, "--git-path") then
        write(repo .. "/other.txt", "concurrent sibling\n")
        run(repo, { "add", "--", "other.txt" })
      end
      return real_run(directory, arguments, options, callback)
    end
    perform("stage_file", 1)
    git.run = real_run
    equal(index(repo, path), "reviewed edit\n")
    equal(index(repo, "other.txt"), "concurrent sibling\n")
  end)

  test("an index transaction holds the real lock until publication", function()
    local repo, buf, path = setup("original\n")
    set_text(buf, "reviewed edit\n")
    refresh(buf)
    local real_run = git.run
    local concurrent_result
    git.run = function(directory, arguments, options, callback)
      if arguments[1] == "apply" then
        write(repo .. "/other.txt", "concurrent sibling\n")
        concurrent_result = vim.system({ "git", "-C", repo, "add", "--", "other.txt" }, { text = false }):wait()
      end
      return real_run(directory, arguments, options, callback)
    end
    perform("stage_file", 1)
    git.run = real_run
    assert(concurrent_result and concurrent_result.code ~= 0)
    assert(concurrent_result.stderr:find("index.lock", 1, true))
    equal(index(repo, path), "reviewed edit\n")
    equal(index(repo, "other.txt"), "other original\n")
    equal(vim.fn.filereadable(repo .. "/.git/index.lock"), 0)
  end)

  test("buffer changes during staging discard the private index and add no undo record", function()
    local repo, buf, path = setup("original\n")
    set_text(buf, "reviewed edit\n")
    refresh(buf)
    local real_run = git.run
    git.run = function(directory, arguments, options, callback)
      if arguments[1] == "apply" then
        set_text(buf, "newer edit\n")
      end
      return real_run(directory, arguments, options, callback)
    end
    assert(hunks.stage_file())
    wait_for(function() return #notices > 0 end)
    git.run = real_run
    assert(notices[1]:find("buffer changed", 1, true), notices[1])
    equal(index(repo, path), "original\n")
    equal(git.text(buf), "newer edit\n")
    equal(vim.fn.filereadable(repo .. "/.git/index.lock"), 0)
    notices = {}
    assert(hunks.undo_stage())
    wait_for(function() return #notices > 0 end)
    assert(notices[1]:find("No staging action to undo", 1, true), notices[1])
  end)

  test("HEAD and branch changes during staging refuse publication without changing index entries", function()
    for _, change in ipairs({ "revision", "branch" }) do
      local repo, buf, path = setup("original\n")
      local alternate = vim.trim(run(repo, { "commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "alternate" }))
      local initial = vim.trim(run(repo, { "rev-parse", "HEAD" }))
      run(repo, { "update-ref", "refs/heads/alternate", initial })
      set_text(buf, "reviewed edit\n")
      refresh(buf)
      local real_run = git.run
      git.run = function(directory, arguments, options, callback)
        if arguments[1] == "apply" then
          if change == "revision" then
            run(repo, { "update-ref", "HEAD", alternate })
          else
            run(repo, { "symbolic-ref", "HEAD", "refs/heads/alternate" })
          end
        end
        return real_run(directory, arguments, options, callback)
      end
      assert(hunks.stage_file())
      wait_for(function() return #notices > 0 end)
      git.run = real_run
      assert(notices[1]:find("changed while preparing the index action", 1, true), notices[1])
      equal(index(repo, path), "original\n")
      equal(index(repo, "other.txt"), "other original\n")
      equal(git.text(buf), "reviewed edit\n")
      equal(vim.fn.filereadable(repo .. "/.git/index.lock"), 0)
    end
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

  test("a queued editor refresh cannot invalidate an explicit preview read", function()
    local _, buf = setup("original\n")
    set_text(buf, "unsaved text\n")
    local injected, real_run = false, git.run
    git.run = function(directory, arguments, options, callback)
      if arguments[1] == "ls-files" and not injected then
        injected = true
        vim.schedule(function() api.nvim_exec_autocmds("TextChanged", { buffer = buf }) end)
      end
      return real_run(directory, arguments, options, callback)
    end
    local win, preview_buf = hunks.preview_hunk("unstaged")
    git.run = real_run
    assert(win and preview_buf, vim.inspect(notices))
    assert(injected)
    local text = table.concat(api.nvim_buf_get_lines(preview_buf, 0, -1, false), "\n")
    assert(text:find("+unsaved text", 1, true), text)
    equal(notices, {})
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
    perform("undo_stage", 1)
    equal(index(worktree, path), original)
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
      if arguments[1] == "rev-parse" and vim.tbl_contains(arguments, "--git-path") then
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
