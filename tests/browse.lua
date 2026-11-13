local api = vim.api

vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.hidden = true

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function command(args)
  return vim.system(args, { text = true }):wait()
end

local function system(args)
  local result = command(args)
  assert(result.code == 0,
    "Command failed: " .. table.concat(args, " ") .. "\n" .. (result.stderr or result.stdout or ""))
  return result.stdout
end

local base = vim.fn.tempname() .. " igit browse"
vim.fn.mkdir(base, "p")
base = assert(vim.uv.fs_realpath(base))
local repository_root = vim.fn.getcwd()

local function git_args(repo, ...)
  local args = { "git", "-C", repo,
    "-c", "user.name=IGit Test",
    "-c", "user.email=igit@example.invalid",
    "-c", "commit.gpgsign=false" }
  vim.list_extend(args, { ... })
  return args
end

local function git(repo, ...)
  return system(git_args(repo, ...))
end

local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
end

local function make_repo(name, remotes)
  local repo = base .. "/" .. name
  system({ "git", "init", "-q", "-b", "main", repo })
  write(repo .. "/README.md", { "initial" })
  git(repo, "add", "-A")
  git(repo, "commit", "-qm", "initial")
  for remote, url in pairs(remotes or {}) do
    git(repo, "remote", "add", remote, url)
  end
  return repo
end

local function edit(path)
  vim.cmd.edit(vim.fn.fnameescape(path))
  return api.nvim_get_current_buf()
end

local browse = require("igit.browse")
local notices = {}
vim.notify = function(message, level, opts)
  notices[#notices + 1] = {
    message = message,
    level = level,
    title = opts and opts.title,
  }
end

local passed = 0

local function equal(actual, expected, label)
  assert(vim.deep_equal(actual, expected),
    (label or "Values differ")
      .. "\nExpected: " .. vim.inspect(expected)
      .. "\nActual: " .. vim.inspect(actual))
end

local function contains(value, expected, label)
  assert(type(value) == "string" and value:find(expected, 1, true),
    (label or "Missing text") .. "\nExpected: " .. expected .. "\nActual: " .. tostring(value))
end

local function wait_for(condition, message)
  assert(vim.wait(5000, condition, 10), message or "Timed out")
end

local function resolve(options)
  local result
  local calls = 0
  local immediate = browse.url(options, function(err, url)
    calls = calls + 1
    result = { err = err, url = url }
  end)
  wait_for(function()
    return result ~= nil
  end, "URL callback timed out")
  vim.wait(20, function()
    return false
  end)
  equal(calls, 1, "URL callback must run exactly once")
  return result.err, result.url, immediate
end

local function expect_url(options, expected)
  local err, url = resolve(options)
  assert(err == nil, err)
  equal(url, expected)
end

local function expect_url_error(options, expected)
  local err, url = resolve(options)
  assert(err ~= nil, "Expected an error")
  equal(url, nil)
  contains(err, expected)
  return err
end

local function test(name, callback)
  notices = {}
  browse.setup({})
  vim.cmd.cd(vim.fn.fnameescape(repository_root))
  local scratch = api.nvim_create_buf(true, false)
  api.nvim_set_current_buf(scratch)
  local ok, err = xpcall(callback, debug.traceback)
  if not ok then
    error(name .. "\n" .. err)
  end
  passed = passed + 1
  print("PASS " .. name)
end

local nested = "nested/空 格#%?&=.txt"
local nested_url = "nested/%E7%A9%BA%20%E6%A0%BC%23%25%3F%26%3D.txt"

local ok, err = xpcall(function()
  test("GitHub current file, cursor, and normalized ranges", function()
    local repo = make_repo("github", { origin = "git@github.com:owner/repo.git" })
    local file = repo .. "/" .. nested
    write(file, { "one", "two", "three", "four", "five", "six", "seven", "eight", "nine" })
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "nested")
    local buf = edit(file)

    expect_url({ buf = buf }, "https://github.com/owner/repo/blob/main/" .. nested_url .. "?plain=1#L1")
    local short_result
    browse.url(function(url_err, url)
      short_result = { err = url_err, url = url }
    end)
    wait_for(function()
      return short_result ~= nil
    end)
    equal(short_result.err, nil)
    equal(short_result.url, "https://github.com/owner/repo/blob/main/" .. nested_url .. "?plain=1#L1")

    api.nvim_win_set_cursor(0, { 3, 0 })
    expect_url({ buf = buf }, "https://github.com/owner/repo/blob/main/" .. nested_url .. "?plain=1#L3")
    expect_url({ buf = buf, line = 9, end_line = 4 },
      "https://github.com/owner/repo/blob/main/" .. nested_url .. "?plain=1#L4-L9")
    expect_url({ buf = buf, line = 5, end_line = 5 },
      "https://github.com/owner/repo/blob/main/" .. nested_url .. "?plain=1#L5")
  end)

  test("GitLab and Bitbucket defaults", function()
    local gitlab = make_repo("gitlab", { origin = "https://gitlab.com/group/sub/repo.git" })
    local gitlab_file = gitlab .. "/src file.txt"
    write(gitlab_file, { "one", "two", "three" })
    git(gitlab, "add", "-A")
    git(gitlab, "commit", "-qm", "source")
    local gitlab_buf = edit(gitlab_file)

    expect_url({ buf = gitlab_buf },
      "https://gitlab.com/group/sub/repo/-/blob/main/src%20file.txt?plain=1#L1")
    expect_url({ buf = gitlab_buf, line = 2, end_line = 3 },
      "https://gitlab.com/group/sub/repo/-/blob/main/src%20file.txt?plain=1#L2-3")

    local bitbucket = make_repo("bitbucket", { origin = "ssh://git@bitbucket.org/team/repo.git" })
    local bitbucket_file = bitbucket .. "/a#b.txt"
    write(bitbucket_file, { "one", "two", "three" })
    git(bitbucket, "add", "-A")
    git(bitbucket, "commit", "-qm", "source")
    local bitbucket_buf = edit(bitbucket_file)

    expect_url({ buf = bitbucket_buf },
      "https://bitbucket.org/team/repo/src/main/a%23b.txt#lines-1")
    expect_url({ buf = bitbucket_buf, line = 2, end_line = 3 },
      "https://bitbucket.org/team/repo/src/main/a%23b.txt#lines-2:3")
  end)

  test("custom provider, differently named upstream, and encoded paths", function()
    local repo = make_repo("encoded-upstream", {
      mirror = "git@git.example.com:team/space 名.git",
    })
    git(repo, "checkout", "-q", "-b", "local-topic")
    git(repo, "config", "branch.local-topic.remote", "mirror")
    git(repo, "config", "branch.local-topic.merge", "refs/heads/release/空#%")
    local file = repo .. "/nested/one two.txt"
    write(file, { "one", "two", "three" })
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "topic")
    local buf = edit(file)
    browse.setup({ hosts = { ["git.example.com"] = "gitlab" } })

    local base_url = "https://git.example.com/team/space%20%E5%90%8D/-"
    expect_url({ buf = buf },
      base_url .. "/blob/release%2F%E7%A9%BA%23%25/nested/one%20two.txt?plain=1#L1")
    expect_url({ buf = buf, line = 1, end_line = 3 },
      base_url .. "/blob/release%2F%E7%A9%BA%23%25/nested/one%20two.txt?plain=1#L1-3")
  end)

  test("HTTPS credentials are removed and custom HTTPS ports are retained", function()
    local repo = make_repo("https-port", {
      origin = "https://user:secret-token@git.example.com:8443/group/repo.git",
    })
    local buf = edit(repo .. "/README.md")
    browse.setup({ hosts = { ["git.example.com"] = "bitbucket" } })

    local err, url = resolve({ buf = buf })
    assert(err == nil, err)
    equal(url, "https://git.example.com:8443/group/repo/src/main/README.md#lines-1")
    assert(not url:find("user", 1, true) and not url:find("secret-token", 1, true),
      "Credentials must not be copied into the URL")
  end)

  test("self-hosted HTTP GitLab remotes retain HTTP and strip credentials", function()
    local repo = make_repo("http-gitlab", {
      origin = "http://deploy:secret-token@gitlab.internal.example:8080/group/app.git",
    })
    local buf = edit(repo .. "/README.md")
    browse.setup({ hosts = { ["gitlab.internal.example"] = "gitlab" } })

    expect_url({ buf = buf },
      "http://gitlab.internal.example:8080/group/app/-/blob/main/README.md?plain=1#L1")
    expect_url({ buf = buf, line = 1, end_line = 2 },
      "http://gitlab.internal.example:8080/group/app/-/blob/main/README.md?plain=1#L1-2")
  end)

  test("SSH URLs drop their port and credentials", function()
    local repo = make_repo("ssh-port", {
      origin = "ssh://git:secret@github.com:2222/owner/repo.git",
    })
    local buf = edit(repo .. "/README.md")
    expect_url({ buf = buf }, "https://github.com/owner/repo/blob/main/README.md?plain=1#L1")
    git(repo, "remote", "set-url", "origin", "https://github.com:443/owner/repo.git")
    expect_url({ buf = buf }, "https://github.com/owner/repo/blob/main/README.md?plain=1#L1")
  end)

  test("detached HEAD uses the commit SHA", function()
    local repo = make_repo("detached", { origin = "git@github.com:owner/repo.git" })
    local sha = trim(git(repo, "rev-parse", "HEAD"))
    git(repo, "checkout", "-q", "--detach")
    local buf = edit(repo .. "/README.md")

    expect_url({ buf = buf }, "https://github.com/owner/repo/blob/" .. sha .. "/README.md?plain=1#L1")
    expect_url({ buf = buf, line = 1 },
      "https://github.com/owner/repo/blob/" .. sha .. "/README.md?plain=1#L1")
  end)

  test("file context ignores cwd", function()
    local repo = make_repo("cwd", { origin = "git@github.com:owner/repo.git" })
    local file = repo .. "/README.md"
    local buf = edit(file)
    vim.cmd.cd(vim.fn.fnameescape(base))

    expect_url({ buf = buf }, "https://github.com/owner/repo/blob/main/README.md?plain=1#L1")
  end)

  test("worktree files use the worktree repository context", function()
    local repo = make_repo("worktree-repo", { origin = "git@github.com:owner/worktree.git" })
    local worktree = base .. "/worktree checkout"
    git(repo, "worktree", "add", "-q", "-b", "feature/editor", worktree)
    local buf = edit(worktree .. "/README.md")
    vim.cmd.cd(vim.fn.fnameescape(base))

    expect_url({ buf = buf },
      "https://github.com/owner/worktree/blob/feature%2Feditor/README.md?plain=1#L1")
  end)

  test("submodule files use the submodule remote", function()
    local sub = make_repo("sub-origin", { origin = "git@github.com:owner/sub.git" })
    local parent = make_repo("sub-parent", { origin = "git@github.com:owner/parent.git" })
    local added = command({
      "git", "-C", parent,
      "-c", "protocol.file.allow=always",
      "submodule", "add", "-q", sub, "modules/sub",
    })
    assert(added.code == 0, added.stderr)
    local submodule = parent .. "/modules/sub"
    git(submodule, "remote", "set-url", "origin", "git@github.com:owner/sub.git")
    git(parent, "add", "-A")
    git(parent, "commit", "-qm", "submodule")

    local buf = edit(submodule .. "/README.md")
    vim.cmd.cd(vim.fn.fnameescape(parent))
    expect_url({ buf = buf },
      "https://github.com/owner/sub/blob/main/README.md?plain=1#L1")
  end)

  test("origin, a sole remote, multiple remotes, and remote overrides", function()
    local origin_repo = make_repo("origin-choice", {
      origin = "git@github.com:owner/origin.git",
      backup = "git@github.com:owner/backup.git",
    })
    local origin_buf = edit(origin_repo .. "/README.md")
    expect_url({ buf = origin_buf },
      "https://github.com/owner/origin/blob/main/README.md?plain=1#L1")

    local sole_repo = make_repo("sole-choice", {
      mine = "git@github.com:owner/sole.git",
    })
    local sole_buf = edit(sole_repo .. "/README.md")
    expect_url({ buf = sole_buf },
      "https://github.com/owner/sole/blob/main/README.md?plain=1#L1")

    local multiple_repo = make_repo("multiple-remotes", {
      alpha = "git@github.com:owner/alpha.git",
      beta = "git@github.com:owner/beta.git",
    })
    local multiple_buf = edit(multiple_repo .. "/README.md")
    expect_url_error({ buf = multiple_buf }, "multiple Git remotes")
    expect_url({ buf = multiple_buf, remote = "beta" },
      "https://github.com/owner/beta/blob/main/README.md?plain=1#L1")
  end)

  test("unsupported, local, file, ext, and injected remotes are rejected", function()
    local repo = make_repo("invalid-remotes", { origin = "git@github.com:owner/repo.git" })
    local buf = edit(repo .. "/README.md")

    git(repo, "remote", "set-url", "origin", "git@unknown.example:owner/repo.git")
    expect_url_error({ buf = buf }, "unsupported Git host")

    git(repo, "remote", "set-url", "origin", base .. "/local.git")
    expect_url_error({ buf = buf }, "local remote paths")

    git(repo, "remote", "set-url", "origin", "file://" .. base .. "/repo.git")
    expect_url_error({ buf = buf }, "file remote URLs")

    git(repo, "remote", "set-url", "origin", "ext::sh -c ignored")
    expect_url_error({ buf = buf }, "ext remote URLs")

    git(repo, "config", "remote.origin.url", "git@github.com:owner/repo.git\n--upload-pack=ignored")
    expect_url_error({ buf = buf }, "invalid remote URL")

    git(repo, "remote", "remove", "origin")
    expect_url_error({ buf = buf }, "no Git remotes")
  end)

  test("scp repository paths encode percent literally", function()
    local repo = make_repo("scp-percent", {
      origin = "git@github.com:owner/repo%20name.git",
    })
    local buf = edit(repo .. "/README.md")
    expect_url({ buf = buf },
      "https://github.com/owner/repo%2520name/blob/main/README.md?plain=1#L1")
  end)

  test("invalid arguments return immediately and errors are notified", function()
    equal(browse.defaults.remote, nil)
    equal(browse.defaults.open, nil)
    equal(browse.defaults.hosts, {})

    local ok, err = browse.open("unknown")
    equal(ok, nil)
    contains(err, "options must be a table")
    equal(#notices, 1)
    equal(notices[1].level, vim.log.levels.ERROR)
    equal(notices[1].title, "igit.nvim")

    notices = {}
    ok, err = browse.open({ buf = 999999 })
    equal(ok, nil)
    contains(err, "valid buffer")

    ok, err = browse.open({ line = 0 })
    equal(ok, nil)
    contains(err, "positive integer")

    local unnamed = api.nvim_create_buf(true, false)
    api.nvim_set_current_buf(unnamed)
    ok, err = browse.open({ buf = unnamed })
    equal(ok, nil)
    contains(err, "not a named working file")

    local callback_result
    local immediate, callback_err = browse.url("unknown", function(url_err)
      callback_result = url_err
    end)
    equal(immediate, nil)
    contains(callback_err, "options must be a table")
    wait_for(function()
      return callback_result ~= nil
    end)
    contains(callback_result, "options must be a table")

    local valid = pcall(browse.setup, { hosts = { [""] = "github" } })
    equal(valid, false)
    valid = pcall(browse.setup, { hosts = { ["git.example.com"] = "unknown" } })
    equal(valid, false)
    valid = pcall(browse.setup, { open = true })
    equal(valid, false)
  end)

  test("outside Git, unsupported hosts, and malformed remote paths report errors", function()
    local outside = base .. "/outside.txt"
    write(outside, { "outside" })
    local outside_buf = edit(outside)
    local err = expect_url_error({ buf = outside_buf }, "igit.browse:")
    assert(err ~= nil)

    local repo = make_repo("notify-errors", { origin = "git@unknown.example:owner/repo.git" })
    local buf = edit(repo .. "/README.md")
    local open_calls = 0
    browse.setup({ open = function()
      open_calls = open_calls + 1
    end })
    local opened, open_error = browse.open({ buf = buf })
    equal(opened, true)
    equal(open_error, nil)
    wait_for(function()
      return #notices > 0
    end)
    contains(notices[#notices].message, "unsupported Git host")
    equal(open_calls, 0)

    git(repo, "remote", "set-url", "origin",
      "https://user:secret@git.example.com:8443/owner/../repo.git")
    browse.setup({ hosts = { ["git.example.com"] = "github" } })
    expect_url_error({ buf = buf }, "malformed remote repository path")
  end)

  test("open uses configured opener, pcall failures, and vim.ui.open fallback", function()
    local repo = make_repo("opener", { origin = "git@github.com:owner/opener.git" })
    local buf = edit(repo .. "/README.md")
    local opened = {}
    browse.setup({
      open = function(url)
        opened[#opened + 1] = url
      end,
    })
    local result, open_error = browse.open({ buf = buf })
    equal(result, true)
    equal(open_error, nil)
    wait_for(function()
      return #opened == 1
    end)
    equal(opened[1], "https://github.com/owner/opener/blob/main/README.md?plain=1#L1")

    notices = {}
    browse.setup({
      open = function()
        error("opener failed")
      end,
    })
    equal(browse.open({ buf = buf }), true)
    wait_for(function()
      return #notices == 1
    end)
    contains(notices[1].message, "could not open URL")
    contains(notices[1].message, "opener failed")

    notices = {}
    browse.setup({
      open = function()
        return nil, "no URL handler"
      end,
    })
    equal(browse.open({ buf = buf }), true)
    wait_for(function()
      return #notices == 1
    end)
    contains(notices[1].message, "no URL handler")

    notices = {}
    local original_open = vim.ui.open
    local fallback_url
    vim.ui.open = function(url)
      fallback_url = url
    end
    local success, fallback_error = xpcall(function()
      browse.setup({})
      equal(browse.open({ buf = buf }), true)
      wait_for(function()
        return fallback_url ~= nil
      end)
      equal(fallback_url, "https://github.com/owner/opener/blob/main/README.md?plain=1#L1")
    end, debug.traceback)
    vim.ui.open = original_open
    if not success then
      error(fallback_error)
    end
  end)

  test("public init API forwards setup options and line ranges", function()
    local repo = make_repo("init-api", { origin = "git@github.com:owner/init.git" })
    write(repo .. "/README.md", { "one", "two", "three", "four" })
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "ranges")
    local buf = edit(repo .. "/README.md")
    local opened = {}
    local igit = require("igit")
    igit.setup({
      browse = {
        open = function(url)
          opened[#opened + 1] = url
        end,
      },
    })
    equal(igit.browse({ buf = buf, line = 2, end_line = 4 }), true)
    wait_for(function()
      return #opened == 1
    end)
    equal(opened[1], "https://github.com/owner/init/blob/main/README.md?plain=1#L2-L4")

    opened = {}
    vim.cmd("2,4 IgitBrowse")
    wait_for(function()
      return #opened == 1
    end)
    equal(opened[1], "https://github.com/owner/init/blob/main/README.md?plain=1#L2-L4")

    opened = {}
    vim.cmd("IgitBrowse")
    wait_for(function()
      return #opened == 1
    end)
    equal(opened[1], "https://github.com/owner/init/blob/main/README.md?plain=1#L1")
  end)
end, debug.traceback)

if not ok then
  vim.fn.delete(base, "rf")
  error(err)
end

vim.fn.delete(base, "rf")
print(string.format("ALL PASS (%d)", passed))
