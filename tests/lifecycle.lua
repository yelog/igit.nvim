local api = vim.api
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.hidden = true
vim.o.lines = 45
vim.o.columns = 140
local igit = require("igit")
local temp = vim.fn.tempname() .. " igit lifecycle 中文"
vim.fn.mkdir(temp, "p")
temp = assert(vim.uv.fs_realpath(temp))
local fixture = temp .. "/fake igit"
vim.fn.writefile({
  "#!/bin/sh",
  'if [ "$1" = "--capabilities" ]; then printf \'%s\\n\' \'{"schema_version":1,"version":"0.1.3","editor_protocol":1,"capabilities":["repository-events"]}\'; exit 0; fi',
  'printf "%s\\n" "$IGIT_NVIM_SESSION" > "$IGIT_LIFECYCLE_RECORD"',
  'while IFS= read -r request; do',
  '  [ "$request" = quit ] && exit 0',
  '  [ "$request" = fail ] && exit 19',
  '  printf "\\033]51;igit-changed;%s\\007" "$request"',
  "done",
}, fixture)
vim.fn.setfperm(fixture, "rwx------")
vim.env.IGIT_LIFECYCLE_RECORD = temp .. "/record"
local notices, passed, sequence, updated, changed = {}, 0, 0, {}, {}
vim.notify = function(message, level)
  notices[#notices + 1] = { message = message, level = level }
end
api.nvim_create_autocmd("User", {
  pattern = "IgitChanged",
  callback = function(event)
    if event.data and event.data.session then
      changed[#changed + 1] = event.data
    end
  end,
})
api.nvim_create_autocmd("User", {
  pattern = "IgitUpdated",
  callback = function(event)
    updated[#updated + 1] = event.data
  end,
})

local function equal(actual, expected)
  assert(vim.deep_equal(actual, expected), "Expected " .. vim.inspect(expected) .. "\nActual " .. vim.inspect(actual))
end

local function wait_for(condition)
  assert(vim.wait(5000, condition, 10), "Timed out; " .. vim.inspect(notices))
end

local function git(repo, arguments)
  local argv = { "git", "-C", repo }
  vim.list_extend(argv, arguments)
  local result = vim.system(argv, { text = false }):wait()
  assert(result.code == 0, result.stderr)
  return result.stdout
end

local function setup(layout)
  sequence = sequence + 1
  local repo = temp .. "/repo " .. sequence
  vim.fn.mkdir(repo, "p")
  git(repo, { "init", "-q" })
  git(repo, { "config", "user.name", "IGit Test" })
  git(repo, { "config", "user.email", "test@example.invalid" })
  vim.fn.writefile({ "original" }, repo .. "/clean.txt")
  vim.fn.writefile({ "dirty baseline" }, repo .. "/dirty.txt")
  git(repo, { "add", "--all" })
  git(repo, { "commit", "-qm", "initial" })
  vim.cmd.cd(vim.fn.fnameescape(repo))
  vim.cmd.edit(vim.fn.fnameescape(repo .. "/clean.txt"))
  local clean = api.nvim_get_current_buf()
  local dirty = vim.fn.bufadd(repo .. "/dirty.txt")
  vim.fn.bufload(dirty)
  igit.setup({
    command = fixture, window = { layout = layout or "float" },
    hunks = { debounce = 10 }, status = { debounce = 10 },
  })
  return repo, clean, dirty
end

local function open()
  vim.fn.delete(vim.env.IGIT_LIFECYCLE_RECORD)
  local term = assert(igit.open())
  wait_for(function() return vim.fn.filereadable(vim.env.IGIT_LIFECYCLE_RECORD) == 1 end)
  return term, vim.fn.readfile(vim.env.IGIT_LIFECYCLE_RECORD)[1]
end

local function clean_up()
  igit.close()
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "igit" then
      api.nvim_buf_delete(buf, { force = true })
    end
  end
  vim.wait(20, function() return false end)
  notices, changed, updated = {}, {}, {}
end

local function test(name, callback)
  clean_up()
  local ok, err = xpcall(callback, debug.traceback)
  assert(ok, name .. "\n" .. tostring(err))
  passed = passed + 1
  print("PASS " .. name)
end

local function lines(buf)
  return api.nvim_buf_get_lines(buf, 0, -1, false)
end

local ok, err = xpcall(function()
  for _, layout in ipairs({ "float", "left", "right", "bottom", "tab" }) do
    test(layout .. " hide checks all loaded clean buffers and preserves the process", function()
      local repo, clean, other = setup(layout)
      vim.bo[clean].autoread = false
      local term, token = open()
      local job = vim.b[term].terminal_job_id
      vim.fn.writefile({ "disk clean replacement", "new line" }, repo .. "/clean.txt")
      vim.fn.writefile({ "disk other replacement" }, repo .. "/dirty.txt")
      assert(igit.close())
      equal(lines(clean), { "disk clean replacement", "new line" })
      equal(lines(other), { "disk other replacement" })
      equal(vim.bo[clean].modified, false)
      equal(vim.bo[clean].autoread, false)
      equal(vim.fn.jobwait({ job }, 0), { -1 })
      wait_for(function()
        local status = igit.status(clean)
        return status and status.unstaged.changed == 1 and status.unstaged.added == 1
      end)
      assert(#updated > 0)
      equal(changed[#changed].session, token)
      equal(changed[#changed].repo, repo)
      equal(notices, {})
    end)
  end

  test("normal exit reconciles disk writes made after the terminal was hidden", function()
    local repo, clean = setup()
    local term = open()
    local job = vim.b[term].terminal_job_id
    assert(igit.close())
    vim.fn.writefile({ "changed while hidden" }, repo .. "/clean.txt")
    vim.fn.chansend(job, "quit\n")
    wait_for(function() return not api.nvim_buf_is_valid(term) end)
    equal(lines(clean), { "changed while hidden" })
    equal(vim.bo[clean].modified, false)
  end)

  test("modified buffers retain text and metadata and warn only when disk changes", function()
    local repo, clean, dirty = setup()
    api.nvim_buf_set_lines(dirty, 0, -1, false, { "unsaved text" })
    vim.bo[dirty].endofline = false
    vim.bo[dirty].fixendofline = false
    local tick = api.nvim_buf_get_changedtick(dirty)
    local term = open()
    local stat = assert(vim.uv.fs_stat(repo .. "/dirty.txt"))
    vim.fn.writefile({ "other baseline" }, repo .. "/dirty.txt")
    assert(vim.uv.fs_utime(repo .. "/dirty.txt", stat.atime.sec, stat.mtime.sec))
    assert(igit.close())
    equal(lines(dirty), { "unsaved text" })
    equal(api.nvim_buf_get_changedtick(dirty), tick)
    equal(vim.bo[dirty].modified, true)
    equal(vim.bo[dirty].endofline, false)
    equal(vim.bo[dirty].fixendofline, false)
    equal(#notices, 1)
    assert(notices[1].message:find("File changed on disk; unsaved buffer kept", 1, true))
    equal(notices[1].level, vim.log.levels.WARN)
    equal(lines(clean), { "original" })
    vim.fn.chansend(vim.b[term].terminal_job_id, "quit\n")
    wait_for(function() return not api.nvim_buf_is_valid(term) end)
    equal(#notices, 1)
  end)

  test("unchanged dirty files are kept without a disk-change warning", function()
    local _, _, dirty = setup()
    api.nvim_buf_set_lines(dirty, 0, -1, false, { "unsaved only" })
    open()
    assert(igit.close())
    equal(lines(dirty), { "unsaved only" })
    equal(notices, {})
  end)

  test("reopening a hidden session retains the baseline for unsaved buffers", function()
    local repo, _, dirty = setup()
    api.nvim_buf_set_lines(dirty, 0, -1, false, { "unsaved text" })
    local term = open()
    assert(igit.close())
    vim.fn.writefile({ "changed while hidden" }, repo .. "/dirty.txt")
    equal(igit.open(), term)
    assert(igit.close())
    equal(lines(dirty), { "unsaved text" })
    equal(#notices, 1)
    assert(notices[1].message:find("unsaved buffer kept", 1, true))
  end)

  test("editor saves advance the baseline without reporting the user's own write", function()
    local _, _, dirty = setup("right")
    local source = api.nvim_get_current_win()
    local term = open()
    api.nvim_set_current_win(source)
    api.nvim_win_set_buf(source, dirty)
    api.nvim_buf_set_lines(dirty, 0, -1, false, { "saved in the editor" })
    vim.cmd("silent write")
    api.nvim_buf_set_lines(dirty, 0, -1, false, { "new unsaved text" })
    igit.close()
    equal(lines(dirty), { "new unsaved text" })
    equal(vim.bo[dirty].modified, true)
    equal(vim.fn.jobwait({ vim.b[term].terminal_job_id }, 0), { -1 })
    equal(notices, {})
  end)

  test("manual window closing and failed exits both reconcile clean files", function()
    local repo, clean = setup("right")
    local term = open()
    vim.fn.writefile({ "manual close replacement" }, repo .. "/clean.txt")
    api.nvim_win_close(api.nvim_get_current_win(), true)
    equal(lines(clean), { "manual close replacement" })
    equal(igit.open(), term)
    vim.fn.writefile({ "failed exit replacement" }, repo .. "/clean.txt")
    vim.fn.chansend(vim.b[term].terminal_job_id, "fail\n")
    wait_for(function() return #notices > 0 end)
    equal(lines(clean), { "failed exit replacement" })
    assert(api.nvim_buf_is_valid(term))
    assert(notices[#notices].message:find("exited with code 19", 1, true))
  end)

  test("authenticated OSC invalidation refreshes one repository without claiming a write", function()
    local repo, clean = setup()
    local outside = temp .. "/outside.txt"
    vim.fn.writefile({ "outside original" }, outside)
    local outside_buf = vim.fn.bufadd(outside)
    vim.fn.bufload(outside_buf)
    local term, token = open()
    local win = api.nvim_get_current_win()
    vim.fn.writefile({ "event replacement" }, repo .. "/clean.txt")
    vim.fn.writefile({ "outside changed" }, outside)
    local function send(session, root, version)
      vim.fn.chansend(vim.b[term].terminal_job_id, vim.json.encode({
        version = version or 1, session = session, repo = root,
      }) .. "\n")
    end
    send("wrong-session", repo)
    send(token, "relative/path")
    vim.wait(50, function() return false end)
    equal(changed, {})
    equal(lines(clean), { "original" })
    send(token, repo)
    wait_for(function() return #changed > 0 end)
    equal(lines(clean), { "event replacement" })
    equal(lines(outside_buf), { "outside original" })
    equal(api.nvim_get_current_win(), win)
    equal(api.nvim_get_current_buf(), term)
    equal(changed[#changed], { repo = repo, session = token })
    equal(git(repo, { "diff", "--cached" }), "")
    equal(notices, {})
  end)

  test("a hidden session can invalidate its repository without stealing focus", function()
    local repo, clean = setup()
    local term, token = open()
    assert(igit.close())
    local win = api.nvim_get_current_win()
    local count = #changed
    vim.fn.writefile({ "hidden event replacement" }, repo .. "/clean.txt")
    api.nvim_exec_autocmds("TermRequest", {
      group = "Igit", buffer = term,
      data = "\027]51;igit-changed;" .. vim.json.encode({ version = 1, session = token, repo = repo }) .. "\027\\",
    })
    wait_for(function() return #changed > count end)
    equal(lines(clean), { "hidden event replacement" })
    equal(api.nvim_get_current_win(), win)
    equal(api.nvim_get_current_buf(), clean)
    equal(notices, {})
  end)

  test("an exited terminal cannot deliver a delayed repository invalidation", function()
    local repo, clean = setup()
    local term, token = open()
    vim.fn.chansend(vim.b[term].terminal_job_id, "fail\n")
    wait_for(function() return #notices > 0 end)
    local count = #changed
    vim.fn.writefile({ "external change after exit" }, repo .. "/clean.txt")
    api.nvim_exec_autocmds("TermRequest", {
      group = "Igit", buffer = term,
      data = "\027]51;igit-changed;" .. vim.json.encode({ version = 1, session = token, repo = repo }),
    })
    vim.wait(50, function() return false end)
    equal(#changed, count)
    equal(lines(clean), { "original" })
    equal(#notices, 1)
    assert(notices[1].message:find("exited with code 19", 1, true))
  end)

  test("large fingerprints use metadata and unrelated buffers are excluded from capture and save hooks", function()
    local repo, clean = setup()
    local large_path = repo .. "/large.txt"
    local outside_path = temp .. "/unrelated large.txt"
    local large = string.rep("x", 1024 * 1024 + 32)
    vim.fn.writefile({ large }, large_path)
    vim.fn.writefile({ large }, outside_path)
    local large_buf = vim.fn.bufadd(large_path)
    local outside_buf = vim.fn.bufadd(outside_path)
    vim.fn.bufload(large_buf)
    vim.fn.bufload(outside_buf)
    api.nvim_buf_set_lines(large_buf, 0, -1, false, { "unsaved large buffer" })
    local real_open, real_read = vim.uv.fs_open, vim.uv.fs_read
    local descriptors, reads, opened = {}, {}, {}
    vim.uv.fs_open = function(path, ...)
      local descriptor, open_error = real_open(path, ...)
      if descriptor then
        descriptors[descriptor] = path
        opened[path] = true
      end
      return descriptor, open_error
    end
    vim.uv.fs_read = function(descriptor, size, offset, ...)
      reads[#reads + 1] = { path = descriptors[descriptor], size = size }
      return real_read(descriptor, size, offset, ...)
    end
    local completed, failure = xpcall(function()
      open()
      api.nvim_exec_autocmds("BufWritePost", { buffer = outside_buf })
      vim.fn.writefile({ "y" .. large:sub(2) }, large_path)
      vim.fn.writefile({ "clean reload alongside large buffer" }, repo .. "/clean.txt")
      assert(igit.close())
      equal(lines(clean), { "clean reload alongside large buffer" })
      equal(lines(large_buf), { "unsaved large buffer" })
      equal(vim.bo[large_buf].modified, true)
      equal(#notices, 1)
      assert(notices[1].message:find(large_path, 1, true), notices[1].message)
      assert(opened[large_path])
      equal(opened[outside_path], nil)
      for _, read in ipairs(reads) do
        assert(read.size <= 1024 * 1024)
        assert(read.path ~= large_path and read.path ~= outside_path)
      end
    end, debug.traceback)
    vim.uv.fs_open, vim.uv.fs_read = real_open, real_read
    assert(completed, failure)
  end)
end, debug.traceback)

clean_up()
igit.setup({ hunks = { enabled = false }, status = { enabled = false } })
vim.fn.delete(temp, "rf")
if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
end
print("Passed " .. passed .. " lifecycle tests")
vim.cmd("qa!")
