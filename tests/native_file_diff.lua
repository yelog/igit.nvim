local api = vim.api
local uv = vim.uv
local binary = assert(vim.env.IGIT_NATIVE_BINARY,
  "Set IGIT_NATIVE_BINARY to a native IGit build with file-diff support")
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.hidden = true
vim.o.columns = 160
vim.o.lines = 50
local notices = {}
vim.notify = function(message)
  notices[#notices + 1] = message
end
local temporary = vim.fn.tempname() .. "-igit-native-diff"
vim.fn.mkdir(temporary, "p")
temporary = uv.fs_realpath(temporary)
vim.env.IGIT_CONFIG_HOME = temporary .. "/config"
vim.env.GIT_CONFIG_GLOBAL = vim.fn.has("win32") == 1 and "NUL" or "/dev/null"
vim.env.GIT_CONFIG_NOSYSTEM = "1"
local filename = "source 中文 [literal] $.txt"
local path = temporary .. "/" .. filename
local function git(arguments)
  local command = {
    "git", "-C", temporary,
    "-c", "user.name=IGit smoke",
    "-c", "user.email=igit@example.invalid",
    "-c", "commit.gpgsign=false",
  }
  vim.list_extend(command, arguments)
  local result = vim.system(command, { text = false }):wait()
  assert(result.code == 0, result.stderr)
  return result.stdout
end
local function read(pathname)
  local descriptor = assert(uv.fs_open(pathname, "r", 384))
  local size = assert(uv.fs_fstat(descriptor)).size
  local value = size > 0 and assert(uv.fs_read(descriptor, size, 0)) or ""
  assert(uv.fs_close(descriptor))
  return value
end
local function lines_with(change20, change60, change100)
  local lines = {}
  for line = 1, 180 do
    lines[line] = "source line " .. line
  end
  lines[20] = change20 or lines[20]
  lines[60] = change60 or lines[60]
  lines[100] = change100 or lines[100]
  return lines
end
local function screen(buffer)
  return table.concat(api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
end
local function wait_for(condition, message)
  assert(vim.wait(15000, condition, 10), message .. "\n" .. table.concat(notices, "\n"))
end
local igit
local function open_diff()
  local buffer = assert(igit.file_diff())
  assert(api.nvim_win_get_config(0).relative == "editor", "Diff did not open in a float")
  wait_for(function()
    return not api.nvim_buf_is_valid(buffer)
      or (screen(buffer):find("Compare with Local:", 1, true) ~= nil
        and screen(buffer):find("Esc Close", 1, true) ~= nil)
  end, "Native diff did not paint")
  assert(api.nvim_buf_is_valid(buffer), "Native viewer exited early")
  return buffer, vim.b[buffer].terminal_job_id
end
local ok, error_message = xpcall(function()
  git({ "init", "-q", "-b", "main" })
  vim.fn.writefile(lines_with(), path)
  vim.fn.writefile({ "original sibling" }, temporary .. "/sibling.txt")
  vim.fn.writefile({ "first", "last" }, temporary .. "/no-final.txt", "b")
  vim.fn.writefile({ "first", "last" }, temporary .. "/bom-change.txt")
  vim.fn.writefile({}, temporary .. "/empty.txt")
  git({ "add", "--all" })
  git({ "commit", "-qm", "initial" })
  vim.fn.writefile(lines_with("staged twenty"), path)
  vim.fn.writefile({ "staged sibling" }, temporary .. "/sibling.txt")
  git({ "add", "--all" })
  vim.fn.writefile(lines_with("working twenty", nil, "working hundred"), path)
  local disk = read(path)
  local head = git({ "rev-parse", "HEAD" })
  local index = read(temporary .. "/.git/index")
  local staged = git({ "diff", "--cached", "--binary" })
  vim.cmd.cd(vim.fn.fnameescape(temporary))
  vim.cmd.edit(vim.fn.fnameescape(path))
  local source = api.nvim_get_current_buf()
  local source_win = api.nvim_get_current_win()
  api.nvim_buf_set_lines(source, 0, -1, false,
    lines_with("working twenty", "unsaved sixty", "unsaved hundred"))
  vim.cmd("let &ul = &ul")
  api.nvim_win_set_cursor(source_win, { 100, 0 })
  igit = require("igit")
  igit.setup({
    command = binary,
    window = { layout = "right" },
    hunks = { enabled = false },
  })
  local terminal, job = open_diff()
  assert(screen(terminal):find("HEAD", 1, true), "Missing HEAD pane")
  assert(screen(terminal):find("Local", 1, true), "Missing Local pane")
  local rows = api.nvim_buf_get_lines(terminal, 0, -1, false)
  local target
  for row, value in ipairs(rows) do
    if value:find("unsaved hundred", 1, true) then
      target = row
      break
    end
  end
  assert(target, "The originating changed line is not visible\n" .. screen(terminal))
  local height = api.nvim_win_get_height(0)
  local expected = 5 + math.floor((height - 6) / 2)
  assert(math.abs(target - expected) <= 1,
    "Origin line did not center: row " .. target .. ", expected " .. expected .. "\n" .. screen(terminal))
  assert(screen(terminal):find("u/U Undo", 1, true), "Undo is missing from the viewer footer")
  print("PASS real native popup includes unsaved content and centers the changed source line")
  vim.fn.chansend(job, "L")
  wait_for(function()
    return not screen(terminal):find("unsaved hundred", 1, true)
  end, "Native hunk restore did not update the viewer")
  vim.fn.chansend(job, "u")
  wait_for(function()
    return screen(terminal):find("unsaved hundred", 1, true) ~= nil
  end, "Lowercase undo did not restore the hunk in the open viewer")
  vim.fn.chansend(job, "L")
  wait_for(function()
    return not screen(terminal):find("unsaved hundred", 1, true)
  end, "Native hunk restore after undo did not update the viewer")
  vim.fn.chansend(job, "U")
  wait_for(function()
    return screen(terminal):find("unsaved hundred", 1, true) ~= nil
  end, "Uppercase undo did not restore the hunk in the open viewer")
  vim.fn.chansend(job, "L")
  wait_for(function()
    return not screen(terminal):find("unsaved hundred", 1, true)
  end, "The restored hunk could not be applied again")
  vim.fn.chansend(job, "q")
  wait_for(function() return not api.nvim_buf_is_valid(terminal) end, "Native viewer did not close")
  assert(api.nvim_get_current_win() == source_win)
  assert(api.nvim_win_get_cursor(source_win)[1] == 100,
    "Restoring a hunk moved the originating source cursor")
  assert(api.nvim_buf_get_lines(source, 99, 100, false)[1] == "source line 100")
  assert(api.nvim_buf_get_lines(source, 59, 60, false)[1] == "unsaved sixty")
  assert(api.nvim_buf_get_lines(source, 19, 20, false)[1] == "working twenty")
  assert(read(path) == disk)
  assert(read(temporary .. "/.git/index") == index)
  assert(git({ "rev-parse", "HEAD" }) == head)
  assert(git({ "diff", "--cached", "--binary" }) == staged)
  print("PASS real native single hunk restore and in-viewer undo preserve disk, HEAD, index, sibling staging, and other buffer hunks")
  vim.cmd("silent undo")
  assert(api.nvim_buf_get_lines(source, 99, 100, false)[1] == "unsaved hundred")
  assert(api.nvim_buf_get_lines(source, 59, 60, false)[1] == "unsaved sixty")
  print("PASS real native hunk restore is one undoable buffer change")
  api.nvim_win_set_cursor(source_win, { 35, 0 })
  terminal, job = open_diff()
  assert(screen(terminal):find("source line 35", 1, true))
  vim.fn.chansend(job, "n")
  wait_for(function()
    return screen(terminal):find("unsaved sixty", 1, true) ~= nil
  end, "Next hunk navigation failed")
  vim.fn.chansend(job, "p")
  wait_for(function()
    return screen(terminal):find("working twenty", 1, true) ~= nil
  end, "Previous hunk navigation failed")
  assert(igit.close())
  wait_for(function() return not api.nvim_buf_is_valid(terminal) end, "Hidden viewer was not retired")
  assert(read(path) == disk)
  assert(read(temporary .. "/.git/index") == index)
  assert(git({ "rev-parse", "HEAD" }) == head)
  assert(#notices == 0, table.concat(notices, "\n"))
  print("PASS real native unchanged-line location, hunk navigation, reopening, and hiding")

  vim.cmd.edit(vim.fn.fnameescape(temporary .. "/no-final.txt"))
  local no_final = api.nvim_get_current_buf()
  assert(not vim.bo[no_final].endofline)
  api.nvim_buf_set_lines(no_final, 1, 2, false, { "edited last" })
  vim.bo[no_final].endofline = true
  vim.cmd("let &ul = &ul")
  api.nvim_win_set_cursor(0, { 2, 0 })
  terminal, job = open_diff()
  vim.fn.chansend(job, "L")
  wait_for(function() return screen(terminal):find("0 differences", 1, true) ~= nil end,
    "The final-line hunk was not restored")
  vim.fn.chansend(job, "q")
  wait_for(function() return not api.nvim_buf_is_valid(terminal) end, "Final-line diff did not close")
  assert(api.nvim_buf_get_lines(no_final, 1, 2, false)[1] == "last")
  assert(not vim.bo[no_final].endofline)
  vim.cmd("silent undo")
  wait_for(function() return vim.bo[no_final].endofline end, "Undo did not restore final-newline metadata")
  assert(api.nvim_buf_get_lines(no_final, 1, 2, false)[1] == "edited last")
  vim.cmd("silent redo")
  wait_for(function() return not vim.bo[no_final].endofline end, "Redo did not restore final-newline metadata")
  assert(read(temporary .. "/no-final.txt") == "first\nlast")
  print("PASS real native final-newline restoration and metadata undo/redo")

  vim.cmd.edit(vim.fn.fnameescape(temporary .. "/bom-change.txt"))
  local bom_buffer = api.nvim_get_current_buf()
  api.nvim_buf_set_lines(bom_buffer, 0, 1, false, { "edited first" })
  vim.bo[bom_buffer].bomb = true
  vim.cmd("let &ul = &ul")
  api.nvim_win_set_cursor(0, { 1, 0 })
  terminal, job = open_diff()
  vim.fn.chansend(job, "L")
  wait_for(function() return screen(terminal):find("0 differences", 1, true) ~= nil end,
    "The BOM hunk was not restored")
  vim.fn.chansend(job, "q")
  wait_for(function() return not api.nvim_buf_is_valid(terminal) end, "BOM diff did not close")
  assert(api.nvim_buf_get_lines(bom_buffer, 0, 1, false)[1] == "first")
  assert(not vim.bo[bom_buffer].bomb)
  vim.cmd("silent undo")
  wait_for(function() return vim.bo[bom_buffer].bomb end, "Undo did not restore BOM metadata")
  assert(api.nvim_buf_get_lines(bom_buffer, 0, 1, false)[1] == "edited first")
  assert(read(temporary .. "/bom-change.txt") == "first\nlast\n")
  print("PASS real native BOM restoration and metadata undo")

  vim.cmd.edit(vim.fn.fnameescape(temporary .. "/new-unsaved.txt"))
  local new_buffer = api.nvim_get_current_buf()
  api.nvim_buf_set_lines(new_buffer, 0, -1, false, { "new unsaved" })
  vim.cmd("let &ul = &ul")
  terminal, job = open_diff()
  vim.fn.chansend(job, "L")
  wait_for(function() return screen(terminal):find("0 differences", 1, true) ~= nil end,
    "The untracked hunk was not restored to empty")
  vim.fn.chansend(job, "q")
  wait_for(function() return not api.nvim_buf_is_valid(terminal) end, "New-file diff did not close")
  assert(vim.deep_equal(api.nvim_buf_get_lines(new_buffer, 0, -1, false), { "" }))
  assert(not uv.fs_stat(temporary .. "/new-unsaved.txt"))
  vim.cmd("silent undo")
  assert(api.nvim_buf_get_lines(new_buffer, 0, 1, false)[1] == "new unsaved")
  print("PASS real native unsaved new-file restoration to empty and undo")

  vim.cmd.edit(vim.fn.fnameescape(temporary .. "/empty.txt"))
  terminal, job = open_diff()
  assert(screen(terminal):find("0 differences", 1, true),
    "An empty buffer was serialized as a blank line")
  vim.fn.chansend(job, "q")
  wait_for(function() return not api.nvim_buf_is_valid(terminal) end, "Empty-file diff did not close")
  assert(read(path) == disk)
  assert(read(temporary .. "/.git/index") == index)
  assert(git({ "rev-parse", "HEAD" }) == head)
  assert(git({ "diff", "--cached", "--binary" }) == staged)
  assert(#notices == 0, table.concat(notices, "\n"))
  print("PASS real native empty-buffer comparison and preserved Git state")
end, debug.traceback)
if igit then
  pcall(igit.close)
end
for _, buffer in ipairs(api.nvim_list_bufs()) do
  if api.nvim_buf_is_valid(buffer) and vim.bo[buffer].filetype == "igit" then
    pcall(api.nvim_buf_delete, buffer, { force = true })
  end
end
vim.cmd("silent! %bdelete!")
vim.fn.delete(temporary, "rf")
if not ok then
  io.stderr:write(tostring(error_message) .. "\n")
  vim.cmd("cquit 1")
end
vim.cmd("qa!")
