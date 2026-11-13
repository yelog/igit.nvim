local api = vim.api
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.hidden = true
vim.o.columns = 140
local temp = vim.fn.tempname() .. " igit editor"
vim.fn.mkdir(temp, "p")
local notices, passed = {}, 0
vim.notify = function(message)
  notices[#notices + 1] = message
end

local function run(arguments)
  local argv = { "git", "-C", temp }
  vim.list_extend(argv, arguments)
  local result = vim.system(argv, { text = false }):wait()
  assert(result.code == 0, result.stderr)
  return result.stdout
end

local function wait_for(condition)
  assert(vim.wait(5000, condition, 10), "Timed out; " .. vim.inspect(notices))
end

local function equal(actual, expected)
  assert(vim.deep_equal(actual, expected), "Expected " .. vim.inspect(expected) .. "\nActual " .. vim.inspect(actual))
end

local function test(name, callback)
  notices = {}
  local ok, err = xpcall(callback, debug.traceback)
  assert(ok, name .. "\n" .. tostring(err))
  equal(notices, {})
  passed = passed + 1
  print("PASS " .. name)
end

run({ "init", "--quiet", "--initial-branch=feature/editor" })
run({ "config", "user.name", "IGit Integration" })
run({ "config", "user.email", "test@example.invalid" })
vim.fn.writefile({ "one", "two", "three" }, temp .. "/editor file.txt")
run({ "add", "--", "editor file.txt" })
run({ "commit", "--quiet", "-m", "integration commit" })
run({ "remote", "add", "origin", "git@git.example.invalid:group/igit.git" })
vim.cmd.edit(vim.fn.fnameescape(temp .. "/editor file.txt"))
local source = api.nvim_get_current_buf()
vim.cmd("runtime plugin/igit.lua")
local igit, hunks = require("igit"), require("igit.hunks")

local ok, err = xpcall(function()
  test("startup attaches hunk signs without setup or an IGit executable", function()
    api.nvim_buf_set_lines(source, 1, 2, false, { "unsaved edit" })
    api.nvim_exec_autocmds("TextChanged", { buffer = source })
    wait_for(function() return #hunks.get_hunks(source) == 1 end)
    equal(api.nvim_buf_get_lines(source, 0, -1, false), { "one", "unsaved edit", "three" })
    for _, buf in ipairs(api.nvim_list_bufs()) do
      assert(vim.bo[buf].buftype ~= "terminal")
    end
  end)

  test("Ex hunk actions update the real index and keep unsaved text", function()
    igit.setup({ command = temp .. "/missing-igit", hunks = { debounce = 10 } })
    api.nvim_win_set_cursor(0, { 2, 0 })
    vim.cmd("IgitPreviewHunk")
    local preview
    for _, win in ipairs(api.nvim_list_wins()) do
      local buf = api.nvim_win_get_buf(win)
      if vim.bo[buf].buftype == "nofile" and vim.bo[buf].filetype == "diff" then
        preview = win
        break
      end
    end
    assert(preview, "hunk preview window was not created")
    api.nvim_win_close(preview, true)
    vim.cmd("Igit hunk preview")
    preview = nil
    for _, win in ipairs(api.nvim_list_wins()) do
      local buf = api.nvim_win_get_buf(win)
      if vim.bo[buf].buftype == "nofile" and vim.bo[buf].filetype == "diff" then
        preview = win
        break
      end
    end
    assert(preview, "hunk action preview window was not created")
    api.nvim_win_close(preview, true)
    vim.cmd("Igit hunk stage")
    wait_for(function() return #hunks.get_hunks(source, true) == 1 end)
    equal(run({ "show", ":editor file.txt" }), "one\nunsaved edit\nthree\n")
    equal(vim.fn.readfile(temp .. "/editor file.txt"), { "one", "two", "three" })
    vim.cmd("IgitUnstageHunk")
    wait_for(function() return #hunks.get_hunks(source, true) == 0 and #hunks.get_hunks(source) == 1 end)
    equal(run({ "show", ":editor file.txt" }), "one\ntwo\nthree\n")
    vim.cmd("IgitResetHunk")
    wait_for(function() return api.nvim_buf_get_lines(source, 1, 2, false)[1] == "two" end)
  end)

  test("file blame commands create and close annotations without moving focus", function()
    local win = api.nvim_get_current_win()
    local before = #api.nvim_list_wins()
    vim.cmd("Igit blame file")
    wait_for(function()
      for _, buf in ipairs(api.nvim_list_bufs()) do
        if vim.bo[buf].filetype == "igitblame" then
          local text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
          if text:find("IGit Integration", 1, true) then
            return true
          end
        end
      end
    end)
    equal(api.nvim_get_current_win(), win)
    equal(api.nvim_get_current_buf(), source)
    equal(#api.nvim_list_wins(), before + 1)
    vim.cmd("IgitBlame")
    equal(#api.nvim_list_wins(), before)
  end)

  test("statusline blame composes with the user's existing statusline", function()
    vim.o.statusline = "%f"
    igit.setup({
      command = temp .. "/missing-igit",
      blame = { inline = { enabled = true, position = "statusline", format = "{author} 100%: {summary}", delay = 0 } },
    })
    wait_for(function() return igit.blame_statusline():find("IGit Integration 100%%: integration commit", 1, true) ~= nil end)
    local status = api.nvim_eval_statusline("%{%v:lua.require'igit'.blame_statusline()%}", {})
    equal(status.str, "IGit Integration 100%: integration commit")
    equal(vim.o.statusline, "%f")
    vim.cmd("IgitInlineBlame")
    equal(igit.blame_statusline(), "")
  end)

  test("whole-file commands and cached status work without native IGit", function()
    igit.setup({ command = temp .. "/missing-igit", hunks = { debounce = 10 }, status = { debounce = 10 } })
    local function edit_action(command)
      local finished = false
      local autocmd = api.nvim_create_autocmd("User", {
        pattern = "IgitChanged",
        callback = function(event)
          if event.data and event.data.buf == source then
            finished = true
          end
        end,
      })
      vim.cmd(command)
      wait_for(function() return finished end)
      api.nvim_del_autocmd(autocmd)
    end
    api.nvim_buf_set_lines(source, 0, -1, false, { "one", "whole edit", "three", "added" })
    edit_action("IgitStageFile")
    wait_for(function()
      return run({ "show", ":editor file.txt" }) == "one\nwhole edit\nthree\nadded\n"
    end)
    equal(vim.fn.readfile(temp .. "/editor file.txt"), { "one", "two", "three" })
    edit_action("IgitUnstageFile")
    wait_for(function()
      return run({ "show", ":editor file.txt" }) == "one\ntwo\nthree\n"
    end)
    equal(api.nvim_buf_get_lines(source, 0, -1, false), { "one", "whole edit", "three", "added" })
    edit_action("IgitResetFile")
    wait_for(function()
      return vim.deep_equal(api.nvim_buf_get_lines(source, 0, -1, false), { "one", "two", "three" })
    end)
    wait_for(function()
      local status = igit.status(source)
      return status and status.branch == "feature/editor" and status.clean
    end)
    local updated = 0
    local autocmd = api.nvim_create_autocmd("User", {
      pattern = "IgitUpdated",
      callback = function(event)
        if event.data and event.data.buf == source then
          updated = updated + 1
        end
      end,
    })
    api.nvim_buf_set_lines(source, 1, 2, false, { "status edit" })
    edit_action("IgitStageHunk")
    wait_for(function()
      local status = igit.status(source)
      return updated > 0 and status and status.staged.changed == 1
    end)
    api.nvim_del_autocmd(autocmd)
    edit_action("IgitUnstageFile")
    wait_for(function()
      return run({ "show", ":editor file.txt" }) == "one\ntwo\nthree\n"
        and vim.deep_equal(api.nvim_buf_get_lines(source, 0, -1, false), { "one", "status edit", "three" })
    end)
    edit_action("IgitResetFile")
    wait_for(function()
      return vim.deep_equal(api.nvim_buf_get_lines(source, 0, -1, false), { "one", "two", "three" })
    end)
  end)

  test("Ex ranges stage only their selected buffer lines", function()
    igit.setup({ command = temp .. "/missing-igit", hunks = { debounce = 10 } })
    api.nvim_buf_set_lines(source, 0, -1, false, { "one", "range two", "range three" })
    local function edit_action(command)
      local finished = false
      local autocmd = api.nvim_create_autocmd("User", {
        pattern = "IgitChanged",
        callback = function(event)
          if event.data and event.data.buf == source then
            finished = true
          end
        end,
      })
      vim.cmd(command)
      wait_for(function() return finished end)
      api.nvim_del_autocmd(autocmd)
    end
    edit_action("2,2Igit hunk stage")
    equal(run({ "show", ":editor file.txt" }), "one\nrange two\nthree\n")
    edit_action("IgitUnstageFile")
    wait_for(function()
      return run({ "show", ":editor file.txt" }) == "one\ntwo\nthree\n"
    end)
    edit_action("IgitResetFile")
    wait_for(function()
      return vim.deep_equal(api.nvim_buf_get_lines(source, 0, -1, false), { "one", "two", "three" })
    end)
  end)

  test("browse commands preserve Ex ranges and never launch the native terminal", function()
    local opened = {}
    igit.setup({
      command = temp .. "/missing-igit",
      browse = {
        hosts = { ["git.example.invalid"] = "gitlab" },
        open = function(url) opened[#opened + 1] = url end,
      },
    })
    vim.cmd("2,3IgitBrowse")
    wait_for(function() return #opened == 1 end)
    equal(opened[1], "https://git.example.invalid/group/igit/-/blob/feature%2Feditor/editor%20file.txt?plain=1#L2-3")
    api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("Igit browse")
    wait_for(function() return #opened == 2 end)
    equal(opened[2], "https://git.example.invalid/group/igit/-/blob/feature%2Feditor/editor%20file.txt?plain=1#L1")
    for _, buf in ipairs(api.nvim_list_bufs()) do
      assert(vim.bo[buf].buftype ~= "terminal")
    end
  end)
end, debug.traceback)

igit.setup({ hunks = { enabled = false } })
vim.fn.delete(temp, "rf")
if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
end
print("Passed " .. passed .. " editor integration tests")
vim.cmd("qa!")
