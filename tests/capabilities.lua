local api = vim.api
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.hidden = true
local igit = require("igit")
local capabilities = require("igit.capabilities")
local temp = vim.fn.tempname() .. " igit capabilities 中文"
vim.fn.mkdir(temp, "p")
temp = assert(vim.uv.fs_realpath(temp))
local source = temp .. "/source.txt"
vim.fn.writefile({ "source" }, source)
vim.cmd.edit(vim.fn.fnameescape(source))
vim.cmd.cd(vim.fn.fnameescape(temp))
local source_buf, source_win = api.nvim_get_current_buf(), api.nvim_get_current_win()
local notices, passed, sequence = {}, 0, 0
vim.notify = function(message)
  notices[#notices + 1] = message
end

local function equal(actual, expected)
  assert(vim.deep_equal(actual, expected), "Expected " .. vim.inspect(expected) .. "\nActual " .. vim.inspect(actual))
end

local function wait_for(condition)
  assert(vim.wait(5000, condition, 10), "Timed out; " .. vim.inspect(notices))
end

local function contract(features, protocol)
  return {
    schema_version = 1, version = "0.1.3", editor_protocol = protocol or 1,
    capabilities = features or { "editor", "revision", "file-diff", "repository-events" },
    future_field = { accepted = true },
  }
end

local function fixture(value, exit_code)
  sequence = sequence + 1
  local path = temp .. "/binary " .. sequence
  local output = type(value) == "table" and vim.json.encode(value) or value
  vim.fn.writefile({
    "#!/bin/sh",
    'for arg do if [ "$arg" = "--capabilities" ]; then',
    '  printf "probe\\n" >> "$IGIT_CAPABILITY_RECORD"',
    "  printf '%s\\n' " .. vim.fn.shellescape(output or "unknown option"),
    "  exit " .. tostring(exit_code or 0),
    "fi; done",
    'printf "%s\\n" "$IGIT_NVIM_SESSION" > "$IGIT_CAPABILITY_SESSION"',
    'while IFS= read -r request; do [ "$request" = quit ] && exit 0; done',
  }, path)
  vim.fn.setfperm(path, "rwx------")
  return path
end

vim.env.IGIT_CAPABILITY_RECORD = temp .. "/probes"
vim.env.IGIT_CAPABILITY_SESSION = temp .. "/session"

local function setup(binary)
  igit.setup({
    command = binary, hunks = { enabled = false }, status = { enabled = false },
  })
end

local function start(binary)
  setup(binary)
  vim.fn.delete(vim.env.IGIT_CAPABILITY_SESSION)
  local buf = assert(igit.open())
  wait_for(function() return vim.fn.filereadable(vim.env.IGIT_CAPABILITY_SESSION) == 1 end)
  return buf, vim.fn.readfile(vim.env.IGIT_CAPABILITY_SESSION)[1]
end

local function clean()
  igit.close()
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "igit" then
      api.nvim_buf_delete(buf, { force = true })
    end
  end
  api.nvim_set_current_win(source_win)
  api.nvim_win_set_buf(source_win, source_buf)
  notices = {}
end

local function test(name, callback)
  clean()
  local ok, err = xpcall(callback, debug.traceback)
  assert(ok, name .. "\n" .. tostring(err))
  passed = passed + 1
  print("PASS " .. name)
end

local function request(buf, kind, token, version)
  api.nvim_exec_autocmds("TermRequest", {
    group = "Igit", buffer = buf,
    data = "\027]51;" .. kind .. ";" .. vim.json.encode({
      version = version or 1, session = token, path = source,
      repo = temp, revision = string.rep("1", 40),
    }) .. "\a",
  })
end

local ok, err = xpcall(function()
  test("capabilities accept future fields and cache by executable identity and argv", function()
    vim.fn.delete(vim.env.IGIT_CAPABILITY_RECORD)
    local binary = fixture(contract())
    local result = capabilities.inspect({ binary }, temp)
    equal(result.version, "0.1.3")
    equal(result.editor_protocol, 1)
    equal(result.executable, binary)
    assert(capabilities.check(result, "editor"))
    assert(capabilities.check(result, "revision"))
    assert(capabilities.check(result, "file-diff"))
    assert(capabilities.check(result, "repository-events"))
    equal(capabilities.inspect({ binary }, temp), result)
    equal(#vim.fn.readfile(vim.env.IGIT_CAPABILITY_RECORD), 1)
    capabilities.inspect({ binary, "--icons", "unicode" }, temp)
    equal(#vim.fn.readfile(vim.env.IGIT_CAPABILITY_RECORD), 2)
    vim.fn.writefile({ "" }, binary, "a")
    equal(capabilities.inspect({ binary }, temp).version, "0.1.3")
    equal(#vim.fn.readfile(vim.env.IGIT_CAPABILITY_RECORD), 3)
  end)

  test("missing and failing command selectors produce actionable diagnostics", function()
    setup(temp .. "/missing")
    local buf, message = igit.open()
    equal(buf, nil)
    assert(message:find("executable not found", 1, true), message)
    setup(function() error("selector failed") end)
    buf, message = igit.open()
    equal(buf, nil)
    assert(message:find("selector failed", 1, true), message)
    equal(api.nvim_get_current_win(), source_win)
  end)

  test("old binaries retain ordinary TUI startup and refuse integrated diff before hiding", function()
    local binary = fixture("unknown option --capabilities", 2)
    local buf = start(binary)
    local win = api.nvim_get_current_win()
    equal(notices, {})
    local diff, message = igit.file_diff()
    equal(diff, nil)
    assert(message:find("capability query failed or is unsupported", 1, true), message)
    equal(api.nvim_get_current_win(), win)
    equal(api.nvim_get_current_buf(), buf)
    equal(vim.fn.jobwait({ vim.b[buf].terminal_job_id }, 0), { -1 })
    assert(igit.close())
    equal(igit.open(), buf)
  end)

  test("invalid JSON and unsupported schemas preserve basic panels but diagnose integrations", function()
    for _, value in ipairs({ "not JSON", { schema_version = 2 }, { schema_version = 1, capabilities = {} } }) do
      clean()
      local buf = start(fixture(value))
      equal(notices, {})
      local diff, message = igit.file_diff()
      equal(diff, nil)
      assert(message:find("capabilit", 1, true), message)
      equal(api.nvim_get_current_buf(), buf)
      equal(api.nvim_get_current_win() ~= source_win, true)
    end
  end)

  test("partial capabilities gate editor and revision requests independently", function()
    local buf, token = start(fixture(contract({ "file-diff" })))
    request(buf, "igit-edit", "foreign-session")
    vim.wait(20, function() return false end)
    equal(notices, {})
    request(buf, "igit-edit", token)
    wait_for(function() return #notices == 1 end)
    assert(notices[1]:find("does not support editor", 1, true), notices[1])
    request(buf, "igit-show-revision", token)
    wait_for(function() return #notices == 2 end)
    assert(notices[2]:find("does not support revision", 1, true), notices[2])
    equal(api.nvim_get_current_buf(), buf)
    equal(api.nvim_buf_get_lines(source_buf, 0, -1, false), { "source" })
  end)

  test("authenticated incompatible editor requests are explained without losing focus", function()
    local buf, token = start(fixture(contract()))
    request(buf, "igit-edit", token, 2)
    wait_for(function() return #notices == 1 end)
    assert(notices[1]:find("request version 2", 1, true), notices[1])
    equal(api.nvim_get_current_buf(), buf)
    clean()
    buf, token = start(fixture(contract({ "editor" }, 2)))
    request(buf, "igit-edit", token)
    wait_for(function() return #notices == 1 end)
    assert(notices[1]:find("editor protocol 2", 1, true), notices[1])
    equal(api.nvim_get_current_buf(), buf)
  end)

  test("checkhealth reports the resolved executable, version, protocol and features", function()
    local binary = fixture(contract())
    setup(function() return binary end)
    vim.cmd("checkhealth igit")
    local output = table.concat(api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert(output:find(binary, 1, true), output)
    assert(output:find("IGit version: 0.1.3", 1, true), output)
    assert(output:find("Editor protocol: 1", 1, true), output)
    for _, feature in ipairs({ "editor", "revision", "file-diff", "repository-events" }) do
      assert(output:find("Supported: " .. feature, 1, true), output)
    end
    vim.cmd("close")
    setup(fixture("old", 2))
    vim.cmd("checkhealth igit")
    output = table.concat(api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert(output:find("Ordinary TUI panels can still start", 1, true), output)
    vim.cmd("close")
  end)
end, debug.traceback)

clean()
vim.fn.delete(temp, "rf")
if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
end
print("Passed " .. passed .. " capability tests")
vim.cmd("qa!")
