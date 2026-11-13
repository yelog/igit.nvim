local api = vim.api
local created_timers = {}
local original_new_timer = vim.uv.new_timer
vim.uv.new_timer = function(...)
  local timer = original_new_timer(...)
  created_timers[#created_timers + 1] = timer
  return timer
end
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.hidden = true
vim.o.lines = 45
vim.o.columns = 160

local temp = vim.fn.tempname() .. " blame 中文"
vim.fn.mkdir(temp, "p")
temp = assert(vim.uv.fs_realpath(temp))

local git_calls = 0
local delayed_blame_started = 0
local delayed_blame_finished = 0
local next_blame_delay = 0
local shared_git = require("igit.git")
local original_run = shared_git.run
shared_git.run = function(repository, arguments, options, callback)
  git_calls = git_calls + 1
  if next_blame_delay > 0 and arguments[1] == "blame" then
    local delay = next_blame_delay
    next_blame_delay = 0
    delayed_blame_started = delayed_blame_started + 1
    return original_run(repository, arguments, options, function(result)
      vim.defer_fn(function()
        delayed_blame_finished = delayed_blame_finished + 1
        callback(result)
      end, delay)
    end)
  end
  return original_run(repository, arguments, options, callback)
end

local blame = require("igit.blame")
blame.setup()

local function equal(actual, expected, label)
  assert(
    vim.deep_equal(actual, expected),
    (label or "Mismatch")
      .. "\nexpected "
      .. vim.inspect(expected)
      .. "\nactual "
      .. vim.inspect(actual)
  )
end

local function wait_for(condition, label)
  assert(vim.wait(10000, condition, 10), label or "Timed out")
end

local function run_git_in(repository, arguments, environment)
  local command = { "git", "-C", repository }
  vim.list_extend(command, arguments)
  local result = vim.system(command, {
    env = vim.tbl_extend(
      "force",
      { GIT_OPTIONAL_LOCKS = "0" },
      environment or {}
    ),
  }):wait()
  assert(result.code == 0, result.stderr)
  return result.stdout
end

local function run_git(arguments, environment)
  return run_git_in(temp, arguments, environment)
end

local function read_bytes(path)
  local handle = assert(io.open(path, "rb"))
  local contents = handle:read("*a")
  handle:close()
  return contents
end

local function contains(text, needle)
  return text:find(needle, 1, true) ~= nil
end

local test_count = 0
local function case(name, callback)
  local success, message = xpcall(callback, debug.traceback)
  assert(success, "FAIL " .. name .. "\n" .. tostring(message))
  test_count = test_count + 1
  print("PASS " .. name)
end

local source_buffer
local source_window
local annotation_window
local annotation_buffer
local disk_contents
local index_contents
local status_contents
local head_revision
local saved_statusline = vim.o.statusline
local file = temp .. "/history 中文.txt"
local old_commit_epoch = os.time({ year = 2001, month = 1, day = 2, hour = 12 })
local recent_commit_epoch = os.time({ year = 2099, month = 12, day = 31, hour = 12 })
local old_inline_date = os.date("%Y-%m-%d", old_commit_epoch)
local old_file_date = os.date("%Y/%m/%d", old_commit_epoch)
local recent_file_date = os.date("%Y/%m/%d", recent_commit_epoch)
local function git_date(epoch)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", epoch)
end
local original_lines = {
  "old retained 中文",
  "recent edited 100%",
  "old tail",
}

local function focus_source()
  api.nvim_set_current_win(source_window)
end

local function find_annotation()
  for window_index = 1, #api.nvim_list_wins() do
    local window = api.nvim_list_wins()[window_index]
    local buffer = api.nvim_win_get_buf(window)
    local position = api.nvim_win_get_position(window)
    local source_position = api.nvim_win_get_position(source_window)
    if window ~= source_window
      and vim.bo[buffer].buftype == "nofile"
      and position[2] < source_position[2]
    then
      return window, buffer
    end
  end
end

local function annotation_lines()
  return api.nvim_buf_get_lines(annotation_buffer, 0, -1, false)
end

local function annotation_content_width()
  local width = 0
  local lines = annotation_lines()
  for line_index = 1, #lines do
    width = math.max(width, vim.fn.strdisplaywidth(vim.trim(lines[line_index])))
  end
  return width
end

local function assert_annotation_width()
  local width = annotation_content_width()
  equal(api.nvim_win_get_width(annotation_window), width)
  local lines = annotation_lines()
  for line_index = 1, #lines do
    equal(vim.fn.strdisplaywidth(lines[line_index]), width)
  end
end

local function extmarks(buffer, virtual_only)
  local result = {}
  for namespace_name, namespace_id in pairs(api.nvim_get_namespaces()) do
    local marks = api.nvim_buf_get_extmarks(
      buffer,
      namespace_id,
      0,
      -1,
      { details = true }
    )
    for mark_index = 1, #marks do
      local mark = marks[mark_index]
      local detail = mark[4]
      if (virtual_only and detail.virt_text)
        or (not virtual_only and detail.hl_group)
      then
        result[#result + 1] = {
          id = mark[1],
          row = mark[2],
          detail = detail,
          namespace = namespace_name,
        }
      end
    end
  end
  table.sort(result, function(first, second)
    return first.row < second.row
  end)
  return result
end

local function virtual_text(row)
  local chunks = {}
  local source_marks = extmarks(source_buffer, true)
  for mark_index = 1, #source_marks do
    local mark = source_marks[mark_index]
    if mark.row == row then
      for chunk_index = 1, #mark.detail.virt_text do
        local chunk = mark.detail.virt_text[chunk_index]
        chunks[#chunks + 1] = chunk[1]
      end
    end
  end
  return table.concat(chunks)
end

local function wait_for_annotations(line_count)
  wait_for(function()
    annotation_window, annotation_buffer = find_annotation()
    if not annotation_buffer then
      return false
    end
    local lines = annotation_lines()
    return #lines == (line_count or api.nvim_buf_line_count(source_buffer))
      and lines[1] ~= ""
  end, "file annotations did not load")
end

local function unchanged()
  equal(read_bytes(file), disk_contents, "disk file changed")
  equal(read_bytes(temp .. "/.git/index"), index_contents, "index bytes changed")
  equal(run_git({ "status", "--porcelain" }), status_contents, "working tree status changed")
  equal(run_git({ "rev-parse", "HEAD" }), head_revision, "HEAD changed")
  assert(vim.uv.fs_stat(temp .. "/.git"), "repository initialization lost")
end

local function age_group(group)
  return assert(tonumber(group:match("^IgitBlameAge(%d+)$")))
end

local success, failure = xpcall(function()
  case("deterministic real Git fixture", function()
    run_git({ "init", "-q" })
    vim.fn.writefile({
      original_lines[1],
      "original middle",
      original_lines[3],
    }, file)
    run_git({ "add", "--", file })
    local function commit(name, email, date, summary)
      run_git({
        "-c",
        "commit.gpgsign=false",
        "commit",
        "-qm",
        summary,
      }, {
        GIT_AUTHOR_NAME = name,
        GIT_COMMITTER_NAME = name,
        GIT_AUTHOR_EMAIL = email,
        GIT_COMMITTER_EMAIL = email,
        GIT_AUTHOR_DATE = date,
        GIT_COMMITTER_DATE = date,
      })
    end
    commit(
      "Alice 中文",
      "alice@example.test",
      git_date(old_commit_epoch),
      "initial 中文 10%"
    )
    vim.fn.writefile(original_lines, file)
    run_git({ "add", "--", file })
    commit(
      "Bob 百分%",
      "bob@example.test",
      git_date(recent_commit_epoch),
      "recent 中文 100%"
    )
    disk_contents = read_bytes(file)
    index_contents = read_bytes(temp .. "/.git/index")
    status_contents = run_git({ "status", "--porcelain" })
    head_revision = run_git({ "rev-parse", "HEAD" })
    vim.cmd.edit(vim.fn.fnameescape(file))
    source_buffer = api.nvim_get_current_buf()
    source_window = api.nvim_get_current_win()
  end)

  case("public defaults, safe setup and validation", function()
    equal(blame.defaults.inline, {
      enabled = false,
      position = "eol",
      format = "{author}, {date}: {summary}",
      date_format = "%Y-%m-%d",
      delay = 250,
    })
    equal(blame.defaults.file, {
      format = "{date} {author}",
      date_format = "%Y/%m/%d",
      width = "auto",
    })
    equal(blame.defaults.colors, {
      age1 = "#252932",
      age2 = "#29354d",
      age3 = "#2d4266",
      age4 = "#315080",
      age5 = "#355e9b",
      uncommitted = "#574151",
    })
    blame.setup()
    assert(
      not pcall(blame.setup, { inline = { position = "invalid" } }),
      "bad inline position accepted"
    )
    assert(
      not pcall(blame.setup, { file = { width = -1 } }),
      "bad file width accepted"
    )
    assert(
      not pcall(blame.setup, { file = { width = "wide" } }),
      "invalid automatic width accepted"
    )
    assert(
      not pcall(blame.setup, { inline = { format = "" } }),
      "empty format accepted"
    )
    blame.setup()
  end)

  case("left annotations, alignment, age colors and close restoration", function()
    focus_source()
    local saved_height = api.nvim_win_get_height(source_window)
    vim.wo[source_window].scrollbind = false
    vim.wo[source_window].cursorbind = true
    vim.wo[source_window].wrap = true
    vim.wo[source_window].foldmethod = "manual"
    vim.wo[source_window].foldenable = true
    vim.wo[source_window].smoothscroll = true
    vim.cmd("1,2fold")
    equal(blame.file_blame(), true)
    equal(api.nvim_get_current_win(), source_window, "blame stole focus")
    wait_for_annotations(3)
    equal(vim.bo[annotation_buffer].modifiable, false)
    equal(vim.bo[annotation_buffer].readonly, true)
    equal(vim.bo[annotation_buffer].buftype, "nofile")
    equal(vim.bo[annotation_buffer].buflisted, false)
    equal(vim.wo[source_window].wrap, false)
    equal(vim.wo[source_window].foldenable, false)
    equal(vim.wo[source_window].scrollbind, false, "source scrollbind was changed")
    equal(vim.wo[source_window].cursorbind, true)
    local lines = annotation_lines()
    assert(
      contains(lines[1], old_file_date)
        and contains(lines[1], "Alice 中文"),
      vim.inspect(lines)
    )
    assert(
      contains(lines[2], recent_file_date)
        and contains(lines[2], "Bob 百分%"),
      vim.inspect(lines)
    )
    equal(lines[1], lines[3], "same committed line received different annotations")
    local visible_width = annotation_content_width()
    assert_annotation_width()
    blame.setup({ file = { width = 20 } })
    wait_for(function()
      return api.nvim_win_get_width(annotation_window) == 20
    end, "fixed file blame width was not applied")
    blame.setup()
    wait_for(function()
      return api.nvim_win_get_width(annotation_window) == visible_width
    end, "automatic file blame width was not restored")
    local groups = {}
    local annotation_marks = extmarks(annotation_buffer, false)
    for mark_index = 1, #annotation_marks do
      local mark = annotation_marks[mark_index]
      assert(
        tostring(mark.detail.hl_group):match("^IgitBlame"),
        "unstable highlight name"
      )
      groups[mark.row] = mark.detail.hl_group
    end
    assert(age_group(groups[0]) < age_group(groups[1]), "age colors are out of order")
    api.nvim_win_set_height(source_window, 2)
    api.nvim_win_set_cursor(source_window, { 3, 0 })
    vim.cmd("normal! zt")
    api.nvim_exec_autocmds("CursorMoved", { buffer = source_buffer })
    local annotation_tick = api.nvim_buf_get_changedtick(annotation_buffer)
    local marks_before = extmarks(annotation_buffer, false)
    wait_for(function()
      local source_view = api.nvim_win_call(source_window, vim.fn.winsaveview)
      local annotation_view = api.nvim_win_call(annotation_window, vim.fn.winsaveview)
      return source_view.topline == annotation_view.topline
        and api.nvim_win_get_cursor(annotation_window)[1] == 3
    end, "file annotations lost source alignment")
    equal(
      api.nvim_buf_get_changedtick(annotation_buffer),
      annotation_tick,
      "cursor movement rewrote annotation rows"
    )
    equal(extmarks(annotation_buffer, false), marks_before, "cursor movement rebuilt highlights")
    api.nvim_win_set_cursor(source_window, { 2, 0 })
    api.nvim_exec_autocmds("CursorMoved", { buffer = source_buffer })
    wait_for(function()
      return api.nvim_win_get_cursor(annotation_window)[1] == 2
    end)
    local pure_scroll_cursor = api.nvim_win_get_cursor(source_window)
    api.nvim_win_call(source_window, function()
      vim.fn.winrestview({ topline = 2 })
    end)
    api.nvim_win_call(source_window, function()
      vim.fn.winrestview({ topline = 1 })
    end)
    api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(source_window) })
    wait_for(function()
      local source_view = api.nvim_win_call(source_window, vim.fn.winsaveview)
      local annotation_view = api.nvim_win_call(annotation_window, vim.fn.winsaveview)
      return source_view.topline == 1
        and annotation_view.topline == 1
        and vim.deep_equal(api.nvim_win_get_cursor(source_window), pure_scroll_cursor)
    end, "pure scroll did not follow source")
    local saved_scrollopt = vim.o.scrollopt
    vim.o.scrollopt = "ver,jump,hor"
    api.nvim_win_call(source_window, function()
      vim.fn.winrestview({ leftcol = 25 })
    end)
    api.nvim_exec_autocmds("CursorMoved", { buffer = source_buffer })
    wait_for(function()
      local source_view = api.nvim_win_call(source_window, vim.fn.winsaveview)
      local annotation_view = api.nvim_win_call(annotation_window, vim.fn.winsaveview)
      return source_view.leftcol == 25 and annotation_view.leftcol == 0
    end, "source horizontal scroll moved annotations out of view")
    vim.o.scrollopt = saved_scrollopt
    focus_source()
    equal(blame.file_blame(), false)
    wait_for(function()
      return not api.nvim_win_is_valid(annotation_window)
        and not api.nvim_buf_is_valid(annotation_buffer)
    end, "file annotation split did not close")
    equal(vim.wo[source_window].scrollbind, false)
    equal(vim.wo[source_window].cursorbind, true)
    equal(vim.wo[source_window].wrap, true)
    equal(vim.wo[source_window].foldenable, true)
    equal(vim.wo[source_window].smoothscroll, true)
    api.nvim_win_set_height(source_window, saved_height)
    equal(blame.file_blame(), true)
    wait_for_annotations(3)
    api.nvim_win_close(annotation_window, true)
    wait_for(function()
      return not api.nvim_win_is_valid(annotation_window)
        and not api.nvim_buf_is_valid(annotation_buffer)
        and vim.wo[source_window].scrollbind == false
        and vim.wo[source_window].wrap == true
    end, "manual annotation close did not clean up")
    equal(vim.wo[source_window].scrollbind, false)
    equal(vim.wo[source_window].cursorbind, true)
    equal(vim.wo[source_window].wrap, true)
    equal(vim.wo[source_window].foldenable, true)
    focus_source()
    vim.cmd("normal! zE")
    equal(blame.file_blame(), true)
    wait_for_annotations(3)
  end)

  case("unsaved edits become uncommitted without writes", function()
    api.nvim_buf_set_lines(source_buffer, 1, 2, false, { "unsaved 中文 50%" })
    blame.refresh(source_buffer)
    wait_for(function()
      return contains(annotation_lines()[2], "Uncommitted changes")
    end, "unsaved line stayed attributed to its old commit")
    assert(contains(annotation_lines()[1], "Alice"), "committed line lost its annotation")
    assert(vim.bo[source_buffer].modified, "unsaved edit was unexpectedly written")
    local original_width = annotation_content_width()
    api.nvim_buf_set_lines(source_buffer, 0, -1, false, {
      "unsaved first",
      "unsaved middle",
      "unsaved last",
    })
    blame.refresh(source_buffer)
    wait_for(function()
      for line_index = 1, #annotation_lines() do
        if annotation_lines()[line_index] ~= "Uncommitted changes"
          and vim.trim(annotation_lines()[line_index]) ~= "Uncommitted changes"
        then
          return false
        end
      end
      return annotation_content_width() ~= original_width
        and api.nvim_win_get_width(annotation_window) == annotation_content_width()
    end, "automatic width did not shrink for uncommitted rows")
    assert_annotation_width()
    api.nvim_buf_set_lines(source_buffer, 0, -1, false, {
      original_lines[1],
      "unsaved 中文 50%",
      original_lines[3],
    })
    blame.refresh(source_buffer)
    wait_for(function()
      return contains(annotation_lines()[1], "Alice")
        and contains(annotation_lines()[2], "Uncommitted changes")
        and contains(annotation_lines()[3], "Alice")
        and annotation_content_width() == original_width
        and api.nvim_win_get_width(annotation_window) == original_width
    end, "automatic width did not expand after blame rows changed")
    assert_annotation_width()
    unchanged()
  end)

  case("inline EOL shows only the cursor line and reuses cached blame", function()
    focus_source()
    api.nvim_win_set_cursor(source_window, { 1, 0 })
    blame.setup({
      inline = {
        enabled = true,
        position = "eol",
        delay = 1,
        format = "{author}|{date}|{summary}|{sha}|{email}",
      },
    })
    wait_for(function()
      return virtual_text(0) ~= ""
    end, "current-line inline blame did not render")
    local marks = extmarks(source_buffer, true)
    equal(#marks, 1, "expected one current-line EOL extmark")
    equal(marks[1].row, 0, "EOL extmark is not on the cursor line")
    local current_text = virtual_text(0)
    assert(contains(current_text, "Alice 中文"), current_text)
    assert(contains(current_text, old_inline_date), current_text)
    assert(contains(current_text, "initial 中文 10%"), current_text)
    assert(contains(current_text, "alice@example.test"), current_text)
    local short_sha = current_text:match("|(%x+)|")
    assert(short_sha and #short_sha == 8, "sha placeholder is not eight characters")
    equal(api.nvim_buf_get_lines(source_buffer, 0, -1, false), {
      original_lines[1],
      "unsaved 中文 50%",
      original_lines[3],
    })
    local calls_before = git_calls
    api.nvim_win_set_cursor(source_window, { 2, 0 })
    api.nvim_exec_autocmds("CursorMoved", { buffer = source_buffer })
    wait_for(function()
      return virtual_text(1) == "Uncommitted changes"
    end, "cursor movement did not repaint the current line")
    equal(#extmarks(source_buffer, true), 1)
    api.nvim_win_set_cursor(source_window, { 3, 0 })
    api.nvim_exec_autocmds("CursorMoved", { buffer = source_buffer })
    wait_for(function()
      return contains(virtual_text(2), "Alice 中文")
    end, "cursor movement did not repaint the old line")
    equal(#extmarks(source_buffer, true), 1)
    equal(git_calls, calls_before, "cursor movement started Git")
    equal(blame.toggle_inline_blame(), false)
    wait_for(function()
      return #extmarks(source_buffer, true) == 0
    end)
    equal(git_calls, calls_before, "disabling inline blame started Git")
    equal(blame.toggle_inline_blame(), true)
    wait_for(function()
      return #extmarks(source_buffer, true) == 1
    end)
    equal(git_calls, calls_before, "enabling inline blame discarded the file cache")
    assert(#annotation_lines() == 3, "file annotations stopped using whole-file blame")
  end)

  case("statusline placement escapes percent and adds no EOL marks", function()
    focus_source()
    blame.setup({
      inline = {
        enabled = true,
        position = "statusline",
        delay = 1,
        format = "{author}|{date}|{summary}|{email}",
      },
    })
    api.nvim_win_set_cursor(source_window, { 1, 0 })
    wait_for(function()
      return contains(blame.statusline(source_buffer), "Alice 中文")
    end, "statusline blame did not load")
    local statusline = blame.statusline(source_buffer)
    assert(contains(statusline, old_inline_date), statusline)
    assert(contains(statusline, "initial 中文 10%%"), statusline)
    assert(contains(statusline, "alice@example.test"), statusline)
    equal(#extmarks(source_buffer, true), 0, "statusline mode added EOL text")
    local calls_before = git_calls
    api.nvim_win_set_cursor(source_window, { 2, 0 })
    api.nvim_exec_autocmds("CursorMoved", { buffer = source_buffer })
    wait_for(function()
      return blame.statusline(source_buffer) == "Uncommitted changes"
    end)
    equal(git_calls, calls_before, "statusline cursor movement started Git")
    equal(#extmarks(source_buffer, true), 0, "statusline mode added EOL text")
  end)

  case("stale async blame cannot overwrite newer buffer contents", function()
    focus_source()
    blame.setup({
      inline = {
        enabled = true,
        position = "statusline",
        delay = 1,
      },
    })
    api.nvim_win_set_cursor(source_window, { 3, 0 })
    wait_for(function()
      return contains(blame.statusline(source_buffer), "Alice 中文")
    end, "committed cursor line did not load")
    local started_before = delayed_blame_started
    local finished_before = delayed_blame_finished
    next_blame_delay = 250
    blame.refresh(source_buffer)
    wait_for(function()
      return delayed_blame_started > started_before
    end, "delayed blame did not start")
    api.nvim_buf_set_lines(source_buffer, 2, 3, false, { "newer async line" })
    blame.refresh(source_buffer)
    wait_for(function()
      return blame.statusline(source_buffer) == "Uncommitted changes"
    end, "newer contents did not replace stale blame")
    wait_for(function()
      return delayed_blame_finished > finished_before
    end, "delayed blame did not finish")
    equal(
      blame.statusline(source_buffer),
      "Uncommitted changes",
      "stale blame overwrote newer contents"
    )
  end)

  case("completion, write, focus and shell events invalidate cached blame", function()
    focus_source()
    blame.setup({
      inline = {
        enabled = true,
        position = "statusline",
        delay = 1,
      },
    })
    wait_for_annotations(3)
    api.nvim_buf_set_lines(source_buffer, 1, 2, false, { "completion edit" })
    local calls_before = git_calls
    api.nvim_exec_autocmds("TextChangedP", { buffer = source_buffer })
    wait_for(function()
      return git_calls > calls_before
    end, "TextChangedP did not invalidate blame")
    wait_for(function()
      return contains(annotation_lines()[2], "Uncommitted changes")
    end, "completion edit stayed stale")
    local refresh_events = { "BufWritePost", "FocusGained", "ShellCmdPost" }
    for event_index = 1, #refresh_events do
      local event = refresh_events[event_index]
      calls_before = git_calls
      if event == "BufWritePost" then
        api.nvim_exec_autocmds(event, { buffer = source_buffer })
      else
        api.nvim_exec_autocmds(event, {})
      end
      wait_for(function()
        return git_calls > calls_before
      end, event .. " did not invalidate blame")
    end
    unchanged()
  end)

  case("FocusGained sees external commits without a hunk watcher", function()
    local external_repository = temp .. "-external 中文"
    vim.fn.mkdir(external_repository, "p")
    external_repository = assert(vim.uv.fs_realpath(external_repository))
    run_git_in(external_repository, { "init", "-q" })
    local relative_path = "external 中文.txt"
    local external_file = external_repository .. "/" .. relative_path
    vim.fn.writefile({ "external old" }, external_file)
    run_git_in(external_repository, { "add", "--", relative_path })
    local first_commit = vim.system({
      "git",
      "-C",
      external_repository,
      "-c",
      "commit.gpgsign=false",
      "commit",
      "-qm",
      "external old",
    }, {
      env = vim.tbl_extend("force", vim.fn.environ(), {
        GIT_AUTHOR_NAME = "External Author",
        GIT_COMMITTER_NAME = "External Author",
        GIT_AUTHOR_EMAIL = "external@example.test",
        GIT_COMMITTER_EMAIL = "external@example.test",
        GIT_AUTHOR_DATE = "2004-04-04T12:00:00Z",
        GIT_COMMITTER_DATE = "2004-04-04T12:00:00Z",
      }),
    }):wait()
    equal(first_commit.code, 0, first_commit.stderr)
    focus_source()
    vim.cmd.edit(vim.fn.fnameescape(external_file))
    local external_buffer = api.nvim_get_current_buf()
    blame.setup({
      inline = {
        enabled = true,
        position = "statusline",
        delay = 1,
      },
    })
    wait_for(function()
      return contains(blame.statusline(external_buffer), "External Author")
    end, "external committed blame did not load")
    local calls_before = git_calls
    vim.fn.writefile({ "external new" }, external_file)
    run_git_in(external_repository, { "add", "--", relative_path })
    local second_commit = vim.system({
      "git",
      "-C",
      external_repository,
      "-c",
      "commit.gpgsign=false",
      "commit",
      "-qm",
      "external new",
    }, {
      env = vim.tbl_extend("force", vim.fn.environ(), {
        GIT_AUTHOR_NAME = "External Author",
        GIT_COMMITTER_NAME = "External Author",
        GIT_AUTHOR_EMAIL = "external@example.test",
        GIT_COMMITTER_EMAIL = "external@example.test",
        GIT_AUTHOR_DATE = "2004-04-05T12:00:00Z",
        GIT_COMMITTER_DATE = "2004-04-05T12:00:00Z",
      }),
    }):wait()
    equal(second_commit.code, 0, second_commit.stderr)
    api.nvim_exec_autocmds("FocusGained", {})
    wait_for(function()
      return git_calls > calls_before
        and blame.statusline(external_buffer) == "Uncommitted changes"
    end, "FocusGained kept stale external blame")
    equal(
      api.nvim_buf_get_lines(external_buffer, 0, -1, false),
      { "external old" },
      "external refresh replaced the live buffer"
    )
    api.nvim_buf_delete(external_buffer, { force = true })
    focus_source()
    vim.fn.delete(external_repository, "rf")
  end)

  case("untracked, missing and unborn files are uncommitted", function()
    local extra_repository = temp .. "/unborn"
    vim.fn.mkdir(extra_repository, "p")
    local init_result = vim.system({
      "git",
      "-C",
      extra_repository,
      "init",
      "-q",
    }):wait()
    equal(init_result.code, 0, init_result.stderr)
    local untracked = temp .. "/untracked 中文.txt"
    vim.fn.writefile({ "untracked 中文" }, untracked)
    local unborn = extra_repository .. "/first.txt"
    vim.fn.writefile({ "unborn line" }, unborn)
    local paths = {
      untracked,
      temp .. "/not-yet-created.txt",
      unborn,
    }
    for path_index = 1, #paths do
      local path = paths[path_index]
      focus_source()
      vim.cmd.edit(vim.fn.fnameescape(path))
      local buffer = api.nvim_get_current_buf()
      if path:find("not-yet-created", 1, true) then
        api.nvim_buf_set_lines(buffer, 0, -1, false, { "new unsaved line" })
        vim.bo[buffer].endofline = false
      end
      blame.refresh(buffer)
      wait_for(function()
        return contains(blame.statusline(buffer), "Uncommitted changes")
      end, "new, untracked, or unborn file was not uncommitted: " .. path)
      if path:find("not-yet-created", 1, true) then
        equal(vim.fn.filereadable(path), 0, "new buffer was written")
        equal(vim.bo[buffer].endofline, false, "missing final newline was lost")
      end
      api.nvim_buf_delete(buffer, { force = true })
    end
    equal(read_bytes(untracked), "untracked 中文\n")
    equal(read_bytes(unborn), "unborn line\n")
    assert(
      not vim.uv.fs_stat(extra_repository .. "/.git/index"),
      "blame initialized an unborn index"
    )
    vim.fn.delete(untracked)
    vim.fn.delete(extra_repository, "rf")
    api.nvim_win_set_buf(source_window, source_buffer)
  end)

  case("committed CRLF blobs match a DOS live buffer", function()
    local crlf_repository = temp .. "-crlf 中文"
    vim.fn.mkdir(crlf_repository, "p")
    crlf_repository = assert(vim.uv.fs_realpath(crlf_repository))
    run_git_in(crlf_repository, { "init", "-q" })
    run_git_in(crlf_repository, { "config", "core.autocrlf", "false" })
    local relative_path = "crlf 中文.txt"
    local crlf_file = crlf_repository .. "/" .. relative_path
    local crlf_contents = "first\r\nsecond 中文\r\n"
    local handle = assert(io.open(crlf_file, "wb"))
    handle:write(crlf_contents)
    handle:close()
    run_git_in(crlf_repository, { "add", "--", relative_path })
    local commit = vim.system({
      "git",
      "-C",
      crlf_repository,
      "-c",
      "commit.gpgsign=false",
      "commit",
      "-qm",
      "crlf",
    }, {
      env = vim.tbl_extend("force", vim.fn.environ(), {
        GIT_AUTHOR_NAME = "CRLF Author",
        GIT_COMMITTER_NAME = "CRLF Author",
        GIT_AUTHOR_EMAIL = "crlf@example.test",
        GIT_COMMITTER_EMAIL = "crlf@example.test",
        GIT_AUTHOR_DATE = "2005-05-05T12:00:00Z",
        GIT_COMMITTER_DATE = "2005-05-05T12:00:00Z",
      }),
    }):wait()
    equal(commit.code, 0, commit.stderr)
    local head_before = run_git_in(crlf_repository, { "rev-parse", "HEAD" })
    focus_source()
    vim.cmd.edit(vim.fn.fnameescape(crlf_file))
    local crlf_buffer = api.nvim_get_current_buf()
    equal(vim.bo[crlf_buffer].fileformat, "dos")
    blame.setup({
      inline = {
        enabled = true,
        position = "statusline",
        delay = 1,
      },
    })
    wait_for(function()
      return contains(blame.statusline(crlf_buffer), "CRLF Author")
    end, "committed CRLF blob was blamed as uncommitted")
    assert(
      not contains(blame.statusline(crlf_buffer), "Uncommitted"),
      "live DOS buffer did not match the committed CRLF blob"
    )
    equal(read_bytes(crlf_file), crlf_contents, "CRLF file was rewritten")
    equal(run_git_in(crlf_repository, { "rev-parse", "HEAD" }), head_before)
    api.nvim_buf_delete(crlf_buffer, { force = true })
    focus_source()
    vim.fn.delete(crlf_repository, "rf")
  end)

  case("idempotent setup, colorscheme, events and source deletion cleanup", function()
    focus_source()
    if not find_annotation() then
      equal(blame.file_blame(), true)
    end
    wait_for_annotations(3)
    local autocmd_count = #api.nvim_get_autocmds({ group = "IgitBlame" })
    local options = {
      inline = {
        enabled = true,
        position = "statusline",
        delay = 1,
      },
    }
    blame.setup(options)
    wait_for_annotations(3)
    local calls_before = git_calls
    blame.setup(options)
    equal(git_calls, calls_before, "repeated setup reread blame")
    assert(
      api.nvim_win_is_valid(annotation_window)
        and api.nvim_buf_is_valid(annotation_buffer),
      "repeated setup removed open annotations"
    )
    equal(
      #api.nvim_get_autocmds({ group = "IgitBlame" }),
      autocmd_count,
      "repeated setup leaked autocmds"
    )
    api.nvim_exec_autocmds("ColorScheme", { pattern = "default" })
    local annotation_marks = extmarks(annotation_buffer, false)
    for mark_index = 1, #annotation_marks do
      local mark = annotation_marks[mark_index]
      assert(
        next(api.nvim_get_hl(0, { name = mark.detail.hl_group, link = false })),
        "colorscheme removed blame highlights"
      )
    end
    api.nvim_buf_set_lines(source_buffer, 2, 3, false, { "event invalidation" })
    calls_before = git_calls
    api.nvim_exec_autocmds("User", {
      pattern = "IgitChanged",
      data = { repo = temp, buf = source_buffer },
    })
    wait_for(function()
      return contains(annotation_lines()[3], "Uncommitted changes")
    end, "IgitChanged left stale annotations")
    assert(git_calls > calls_before, "IgitChanged did not refresh blame")
    api.nvim_buf_delete(source_buffer, { force = true })
    wait_for(function()
      return not api.nvim_win_is_valid(annotation_window)
        and not api.nvim_buf_is_valid(annotation_buffer)
    end, "source deletion did not close annotations")
    equal(#api.nvim_list_wins(), 1, "source deletion leaked a blame window")
    local buffers = api.nvim_list_bufs()
    for buffer_index = 1, #buffers do
      local buffer = buffers[buffer_index]
      assert(
        not api.nvim_buf_get_name(buffer):lower():match("igit.*blame"),
        "source deletion leaked a blame buffer"
      )
    end
    wait_for(function()
      for timer_index = 1, #created_timers do
        if not created_timers[timer_index]:is_closing() then
          return false
        end
      end
      return true
    end, "source deletion leaked a blame timer")
  end)

  case("final disk, index, HEAD and status invariants", function()
    unchanged()
    equal(vim.o.statusline, saved_statusline, "blame replaced the global statusline")
  end)
end, debug.traceback)

local buffers = api.nvim_list_bufs()
for buffer_index = 1, #buffers do
  local buffer = buffers[buffer_index]
  pcall(api.nvim_buf_delete, buffer, { force = true })
end
vim.fn.delete(temp, "rf")
if not success then
  io.stderr:write(tostring(failure) .. "\n")
  vim.cmd("cquit 1")
else
  print("PASS all " .. test_count .. " blame integration cases")
  vim.cmd("qa!")
end
