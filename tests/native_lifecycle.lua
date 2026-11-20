local api = vim.api
local uv = vim.uv
local binary = assert(vim.env.IGIT_NATIVE_BINARY, "Set IGIT_NATIVE_BINARY to the native IGit build")
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.hidden = true
vim.o.columns = 160
vim.o.lines = 50

local temporary = vim.fn.tempname() .. "-igit-native-lifecycle"
vim.fn.mkdir(temporary .. "/repo", "p")
temporary = assert(uv.fs_realpath(temporary))
local repo = temporary .. "/repo"
vim.env.IGIT_STATE_DIR = temporary .. "/state"
vim.env.IGIT_CONFIG_HOME = temporary .. "/config"
vim.fn.mkdir(vim.env.IGIT_CONFIG_HOME, "p")
vim.fn.writefile({ "[updates]", "check_on_startup = false" }, vim.env.IGIT_CONFIG_HOME .. "/settings.toml")
vim.env.GIT_CONFIG_GLOBAL = vim.fn.has("win32") == 1 and "NUL" or "/dev/null"
vim.env.GIT_CONFIG_NOSYSTEM = "1"
local notices = {}
vim.notify = function(message)
  notices[#notices + 1] = message
end

local function git(arguments)
  local command = {
    "git", "-C", repo, "-c", "user.name=Lifecycle test",
    "-c", "user.email=lifecycle@example.invalid", "-c", "commit.gpgsign=false",
    "-c", "core.hooksPath=/dev/null",
  }
  vim.list_extend(command, arguments)
  local result = vim.system(command, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return result.stdout
end

local function wait_for(condition, message)
  assert(vim.wait(15000, condition, 10), message .. "\n" .. table.concat(notices, "\n"))
end

local function text(buffer)
  return table.concat(api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
end

local terminal, job
local success, failure = xpcall(function()
  local queried = vim.system({ binary, "--capabilities" }, { text = true }):wait()
  assert(queried.code == 0, queried.stderr)
  local capabilities = vim.json.decode(queried.stdout)
  assert(capabilities.schema_version == 1 and capabilities.editor_protocol == 1)
  for _, feature in ipairs({ "editor", "revision", "file-diff", "repository-events" }) do
    assert(vim.tbl_contains(capabilities.capabilities, feature), "Missing capability: " .. feature)
  end

  git({ "init", "-q", "-b", "main" })
  local clean_path = repo .. "/clean 中文.txt"
  local dirty_path = repo .. "/dirty.txt"
  vim.fn.writefile({ "base clean" }, clean_path)
  vim.fn.writefile({ "base dirty" }, dirty_path)
  git({ "add", "." })
  git({ "commit", "-qm", "base" })
  git({ "checkout", "-qb", "incoming" })
  vim.fn.writefile({ "incoming clean" }, clean_path)
  vim.fn.writefile({ "incoming dirty" }, dirty_path)
  git({ "commit", "-qam", "incoming" })
  git({ "checkout", "-q", "main" })
  vim.fn.writefile({ "Visible startup marker" }, repo .. "/startup-marker.txt")
  vim.cmd.cd(vim.fn.fnameescape(repo))
  vim.cmd.edit(vim.fn.fnameescape(clean_path))
  local clean_buffer = api.nvim_get_current_buf()
  local dirty_buffer = vim.fn.bufadd(dirty_path)
  vim.fn.bufload(dirty_buffer)
  api.nvim_buf_set_lines(dirty_buffer, 0, -1, false, { "unsaved private edits" })
  local dirty_tick = api.nvim_buf_get_changedtick(dirty_buffer)
  local invalidations = 0
  api.nvim_create_autocmd("User", {
    pattern = "IgitChanged",
    callback = function(event)
      if event.data and event.data.repo == repo then
        invalidations = invalidations + 1
      end
    end,
  })
  local igit = require("igit")
  igit.setup({
    command = binary,
    window = { layout = "float", width = 0.9, height = 0.9 },
    hunks = { enabled = false },
  })
  terminal = assert(igit.open())
  job = vim.b[terminal].terminal_job_id
  wait_for(function()
    return api.nvim_buf_is_valid(terminal) and text(terminal):find("startup%-marker%.txt") ~= nil
  end, "Native workspace did not finish loading")
  local before = invalidations
  git({ "checkout", "-q", "incoming" })
  api.nvim_chan_send(job, "\27[15~")
  wait_for(function()
    return invalidations > before and text(clean_buffer) == "incoming clean"
  end, "Native repository invalidation did not reconcile the clean buffer")
  assert(api.nvim_get_current_buf() == terminal, "Invalidation stole terminal focus")
  assert(text(dirty_buffer) == "unsaved private edits", "Invalidation replaced unsaved text")
  assert(api.nvim_buf_get_changedtick(dirty_buffer) == dirty_tick, "Invalidation changed the dirty buffer")
  assert(vim.bo[dirty_buffer].modified, "Invalidation cleared modified state")
  assert(table.concat(notices, "\n"):find("changed on disk", 1, true), "Missing concurrent disk-edit warning")

  git({ "checkout", "-q", "main" })
  igit.close()
  assert(vim.fn.jobwait({ job }, 0)[1] == -1, "Hiding stopped the native session")
  assert(api.nvim_get_current_buf() == clean_buffer, "Hiding did not restore the source buffer")
  wait_for(function()
    return text(clean_buffer) == "base clean"
  end, "Hiding did not reconcile the changed clean buffer")
  assert(text(dirty_buffer) == "unsaved private edits", "Hiding replaced unsaved text")
  assert(api.nvim_buf_get_changedtick(dirty_buffer) == dirty_tick, "Hiding changed the dirty buffer")
  assert(vim.bo[dirty_buffer].modified, "Hiding cleared modified state")
  git({ "checkout", "-q", "incoming" })
  api.nvim_chan_send(job, "q")
  wait_for(function()
    return vim.fn.jobwait({ job }, 0)[1] ~= -1 and text(clean_buffer) == "incoming clean"
  end, "Hidden native exit did not reconcile the changed file")
  assert(text(dirty_buffer) == "unsaved private edits", "Exit replaced unsaved text")
  assert(api.nvim_buf_get_changedtick(dirty_buffer) == dirty_tick, "Exit changed the dirty buffer")
  assert(vim.bo[dirty_buffer].modified, "Exit cleared modified state")
  assert(git({ "diff", "--cached", "--name-only" }) == "", "Lifecycle changed the index")
  assert(git({ "diff", "--name-only" }) == "", "Lifecycle wrote buffer edits to disk")
  print("PASS native capabilities, repository invalidation, hide/exit sync and dirty-buffer preservation")
end, debug.traceback)

if job and vim.fn.jobwait({ job }, 0)[1] == -1 then
  vim.fn.jobstop(job)
  vim.fn.jobwait({ job }, 1000)
end
vim.cmd.cd(vim.fn.fnameescape(vim.fn.fnamemodify(temporary, ":h")))
vim.fn.delete(temporary, "rf")
if not success then
  io.stderr:write(failure .. "\n")
  vim.cmd.cquit(1)
else
  vim.cmd.qa({ bang = true })
end
