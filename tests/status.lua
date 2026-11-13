local api = vim.api
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.hidden = true
local git = require("igit.git")
local hunks = require("igit.hunks")
local status = require("igit.status")
local temp = vim.fn.tempname() .. " igit status 中文"
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

local function run(repo, arguments, options)
  local argv = { "git", "--literal-pathspecs", "-C", repo }
  vim.list_extend(argv, arguments)
  local result = vim.system(argv, vim.tbl_extend("force", { text = false }, options or {})):wait()
  assert(result.code == 0, result.stderr)
  return result.stdout
end

local function write(path, text)
  local file = assert(io.open(path, "wb"))
  file:write(text)
  file:close()
end

local function refresh_status(buf)
  for attempt = 1, 3 do
    local finished, failure
    status.refresh(buf, function(err)
      failure, finished = err, true
    end)
    wait_for(function() return finished end)
    if not failure then
      return
    end
    assert(attempt < 3 and failure:find("buffer changed", 1, true), failure)
  end
end

local function refresh_hunks(buf)
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

local function setup_repository()
  sequence = sequence + 1
  local repo = temp .. "/repo " .. sequence
  vim.fn.mkdir(repo, "p")
  run(repo, { "init", "--quiet", "--initial-branch=feature/status" })
  run(repo, { "config", "user.name", "IGit Test" })
  run(repo, { "config", "user.email", "test@example.invalid" })
  write(repo .. "/file.txt", "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n")
  write(repo .. "/other.txt", "other\n")
  run(repo, { "add", "--", "file.txt", "other.txt" })
  run(repo, { "commit", "--quiet", "-m", "initial" })
  vim.cmd.edit(vim.fn.fnameescape(repo .. "/file.txt"))
  local buf = api.nvim_get_current_buf()
  notices = {}
  return repo, buf
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

local function test(name, callback)
  local ok, err = xpcall(callback, debug.traceback)
  assert(ok, name .. "\n" .. tostring(err))
  passed = passed + 1
  print("PASS " .. name)
end

local ok, err = xpcall(function()
  status.setup({ debounce = 10 })
  hunks.setup({ debounce = 10 })

  test("status access is synchronous and uses the cached branch and file state", function()
    local _, buf = setup_repository()
    local updated = 0
    local autocmd = api.nvim_create_autocmd("User", {
      pattern = "IgitUpdated",
      callback = function(event)
        if event.data and event.data.buf == buf then
          updated = updated + 1
        end
      end,
    })
    refresh_status(buf)
    local current = status.get(buf)
    equal(current.branch, "feature/status")
    equal(current.head, "feature/status")
    equal(current.path, "file.txt")
    equal(current.clean, true)
    equal(current.file_state, "clean")
    equal(current.detached, false)
    equal(current.unborn, false)
    equal(current.unstaged, { added = 0, changed = 0, removed = 0 })
    equal(current.staged, { added = 0, changed = 0, removed = 0 })
    assert(updated > 0)

    local calls, real_run = 0, git.run
    git.run = function(...)
      calls = calls + 1
      return real_run(...)
    end
    for _ = 1, 20 do
      assert(status.get(buf))
    end
    git.run = real_run
    equal(calls, 0)
    api.nvim_del_autocmd(autocmd)
  end)

  test("hunk summaries publish unstaged and staged counts without extra Git reads", function()
    local repo, buf = setup_repository()
    refresh_status(buf)
    local working = "one\nchanged two\nthree\nfour\ninserted five\nfive\nsix\neight\nnine\nten\n"
    set_text(buf, working)
    refresh_hunks(buf)
    wait_for(function()
      local current = status.get(buf)
      return current and current.unstaged.changed == 1
        and current.unstaged.added == 1 and current.unstaged.removed == 1
    end)
    local current = status.get(buf)
    equal(current.added, 1)
    equal(current.changed, 1)
    equal(current.removed, 1)

    write(repo .. "/file.txt", "one\ntwo\nthree\nfour\nstaged five\nsix\nseven\neight\nnine\nten\n")
    run(repo, { "add", "--", "file.txt" })
    refresh_hunks(buf)
    wait_for(function()
      local value = status.get(buf)
      return value and value.staged.changed == 1 and value.staged_changes
    end)
    current = status.get(buf)
    equal(current.staged.changed, 1)
    equal(current.unstaged.changed > 0, true)
  end)

  test("external index and branch changes refresh through the Git directory watcher", function()
    local repo, buf = setup_repository()
    refresh_status(buf)
    write(repo .. "/file.txt", "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\nexternal\n")
    run(repo, { "add", "--", "file.txt" })
    wait_for(function()
      local current = status.get(buf)
      return current and current.staged_changes
    end)
    run(repo, { "checkout", "--quiet", "-b", "external-branch" })
    wait_for(function()
      local current = status.get(buf)
      return current and current.branch == "external-branch"
    end)
  end)

  test("status parsing distinguishes index-only and worktree-only changes without hunk counts", function()
    local repo, buf = setup_repository()
    hunks.setup({ enabled = false })
    refresh_status(buf)
    local current = status.get(buf)
    equal(current.index_status, ".")
    equal(current.worktree_status, ".")
    equal(current.clean, true)

    write(repo .. "/file.txt", "one\ntwo\nchanged on disk\nfour\nfive\nsix\nseven\neight\nnine\nten\n")
    refresh_status(buf)
    current = status.get(buf)
    equal(current.index_status, ".")
    equal(current.worktree_status, "M")
    equal(current.file_state, "modified")
    equal(current.clean, false)
    equal(current.modified, true)
    equal(current.staged_changes, false)
    equal(current.unstaged_changes, true)
    equal(current.in_head, true)
    equal(current.unstaged, { added = 0, changed = 0, removed = 0 })

    run(repo, { "add", "--", "file.txt" })
    refresh_status(buf)
    current = status.get(buf)
    equal(current.index_status, "M")
    equal(current.worktree_status, ".")
    equal(current.file_state, "modified")
    equal(current.clean, false)
    equal(current.modified, true)
    equal(current.staged_changes, true)
    equal(current.unstaged_changes, false)
    equal(current.in_head, true)
    equal(current.staged, { added = 0, changed = 0, removed = 0 })
  end)

  test("buffer-only edits are modified even when the worktree is clean", function()
    local _, buf = setup_repository()
    hunks.setup({ enabled = false })
    set_text(buf, "one\nbuffer only\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n")
    refresh_status(buf)
    local current = status.get(buf)
    equal(current.buffer_modified, true)
    equal(current.worktree_status, ".")
    equal(current.file_state, "modified")
    equal(current.clean, false)
    equal(current.modified, true)
    equal(current.unstaged_changes, true)
  end)

  test("ignored and conflicted records are represented explicitly", function()
    local repo, buf = setup_repository()
    hunks.setup({ enabled = false })
    write(repo .. "/.gitignore", "ignored.txt\n")
    write(repo .. "/ignored.txt", "ignored\n")
    vim.cmd.edit(vim.fn.fnameescape(repo .. "/ignored.txt"))
    local ignored_buf = api.nvim_get_current_buf()
    refresh_status(ignored_buf)
    local current = status.get(ignored_buf)
    equal(current.ignored, true)
    equal(current.file_state, "ignored")
    equal(current.modified, false)
    equal(current.in_head, false)

    vim.cmd.edit(vim.fn.fnameescape(repo .. "/file.txt"))
    local oid = vim.trim(run(repo, { "rev-parse", "HEAD:file.txt" }))
    local stages = "0 " .. string.rep("0", #oid) .. "\tfile.txt\n"
    for stage = 1, 3 do
      stages = stages .. "100644 " .. oid .. " " .. stage .. "\tfile.txt\n"
    end
    run(repo, { "update-index", "--index-info" }, { stdin = stages })
    refresh_status(buf)
    current = status.get(buf)
    equal(current.conflicted, true)
    equal(current.file_state, "conflicted")
    equal(current.index_status, "U")
    equal(current.worktree_status, "U")
    equal(current.clean, false)
    equal(current.modified, true)
  end)

  test("renamed target paths are added rather than treated as tracked modifications", function()
    local repo = temp .. "/renamed"
    vim.fn.mkdir(repo, "p")
    run(repo, { "init", "--quiet", "--initial-branch=feature/rename" })
    run(repo, { "config", "user.name", "IGit Test" })
    run(repo, { "config", "user.email", "test@example.invalid" })
    write(repo .. "/old name.txt", "tracked\n")
    run(repo, { "add", "--", "old name.txt" })
    run(repo, { "commit", "--quiet", "-m", "initial" })
    run(repo, { "mv", "--", "old name.txt", "new name.txt" })
    vim.cmd.edit(vim.fn.fnameescape(repo .. "/new name.txt"))
    local buf = api.nvim_get_current_buf()
    hunks.setup({ enabled = false })
    refresh_status(buf)
    local current = status.get(buf)
    equal(current.path, "new name.txt")
    assert(current.index_status == "A" or current.index_status == "R", current.index_status)
    equal(current.file_state, "added")
    equal(current.in_head, false)
    equal(current.staged_changes, true)
  end)

  test("non-repository buffers have no status and unborn and detached HEAD are explicit", function()
    local outside = temp .. "/outside.txt"
    write(outside, "outside\n")
    vim.cmd.edit(vim.fn.fnameescape(outside))
    local outside_buf = api.nvim_get_current_buf()
    local finished, failure
    status.refresh(outside_buf, function(message)
      failure, finished = message, true
    end)
    wait_for(function() return finished end)
    assert(failure and failure:find("not in a Git working tree", 1, true), failure)
    equal(status.get(outside_buf), nil)

    local unborn = temp .. "/unborn"
    vim.fn.mkdir(unborn, "p")
    run(unborn, { "init", "--quiet", "--initial-branch=main" })
    write(unborn .. "/new.txt", "new\n")
    vim.cmd.edit(vim.fn.fnameescape(unborn .. "/new.txt"))
    local unborn_buf = api.nvim_get_current_buf()
    refresh_status(unborn_buf)
    local current = status.get(unborn_buf)
    equal(current.unborn, true)
    equal(current.branch, "main")
    equal(current.untracked, true)
    equal(current.file_state, "added")
    equal(current.in_head, false)

    local repo, buf = setup_repository()
    refresh_status(buf)
    run(repo, { "checkout", "--quiet", "--detach" })
    refresh_status(buf)
    current = status.get(buf)
    equal(current.detached, true)
    equal(#current.branch, 8)
    equal(current.branch, current.oid:sub(1, 8))
  end)
end, debug.traceback)

status.setup({ enabled = false })
hunks.setup({ enabled = false })
vim.fn.delete(temp, "rf")
if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
end
print("Passed " .. passed .. " status tests")
vim.cmd("qa!")
