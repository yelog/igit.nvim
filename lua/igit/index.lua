local M = {}
local uv = vim.uv
local git = require("igit.git")

function M.read_entry(context, options, callback)
  git.run(context.repo, { "ls-files", "--stage", "--debug", "-z", "--", context.path }, options, function(result)
    if result.code ~= 0 then
      return callback(git.error(result))
    end
    if result.stdout == "" then
      return callback(nil, { entry = "", flags = 0 })
    end
    local entry, flags, remainder = result.stdout:match("^(.-%z).-\tflags: (%x+)\n(.*)$")
    if not entry or remainder ~= "" then
      return callback("The file's index entry changed or has conflicts; refresh and retry")
    end
    flags = bit.band(tonumber(flags, 16), 0x60008000)
    if bit.band(flags, 0x20000000) ~= 0 then
      return callback("Index actions do not support intent-to-add entries")
    end
    callback(nil, { entry = entry, flags = flags })
  end)
end

local function copy_index(path, descriptor)
  local source, open_error = uv.fs_open(path, "r", 0)
  if not source then
    if open_error and open_error:find("ENOENT", 1, true) then
      return true, false
    end
    return nil, open_error
  end
  local stat, stat_error = uv.fs_fstat(source)
  if not stat then
    uv.fs_close(source)
    return nil, stat_error
  end
  local offset = 0
  while offset < stat.size do
    local bytes, read_error = uv.fs_read(source, math.min(65536, stat.size - offset), offset)
    if not bytes or #bytes == 0 then
      uv.fs_close(source)
      return nil, read_error or "Could not read the complete index"
    end
    local written = 0
    while written < #bytes do
      local count, write_error = uv.fs_write(descriptor, bytes:sub(written + 1), offset + written)
      if not count or count == 0 then
        uv.fs_close(source)
        return nil, write_error or "Could not copy the index"
      end
      written = written + count
    end
    offset = offset + #bytes
  end
  uv.fs_close(source)
  local permitted, permission_error = uv.fs_fchmod(descriptor, bit.band(stat.mode, 511))
  if not permitted then
    return nil, permission_error
  end
  return true, true
end

function M.update(context, expected, operation, callback)
  git.run(context.repo, { "rev-parse", "--path-format=absolute", "--git-path", "index" }, {}, function(location)
    if location.code ~= 0 then
      return callback(git.error(location))
    end
    local path = location.stdout:gsub("\r?\n$", "")
    local lock = path .. ".lock"
    local descriptor, lock_error = uv.fs_open(lock, "wx", 438)
    if not descriptor then
      return callback("Could not lock the Git index; retry after other Git operations finish: " .. tostring(lock_error))
    end
    uv.fs_close(descriptor)
    local directory, candidate
    local function finish(message, before, after)
      if candidate then
        uv.fs_unlink(candidate .. ".lock")
        uv.fs_unlink(candidate)
      end
      if directory then
        uv.fs_rmdir(directory)
      end
      uv.fs_unlink(lock)
      callback(message, before, after)
    end
    local directory_error
    directory, directory_error = uv.fs_mkdtemp(path .. ".igit-XXXXXX")
    if not directory then
      return finish("Could not prepare a private index directory: " .. tostring(directory_error))
    end
    candidate = directory .. "/index"
    local private, private_error = uv.fs_open(candidate, "wx", 438)
    if not private then
      return finish("Could not create the private Git index: " .. tostring(private_error))
    end
    local copied, existing = copy_index(path, private)
    uv.fs_close(private)
    if not copied then
      return finish("Could not prepare the Git index: " .. tostring(existing))
    end
    local settings = { env = {
      GIT_INDEX_FILE = candidate,
      GIT_OPTIONAL_LOCKS = "0",
      GIT_NO_LAZY_FETCH = "1",
    } }
    local function run(arguments, options, done)
      git.run(context.repo, arguments, vim.tbl_extend("force", settings, options or {}), done)
    end
    local function read_entry(done)
      M.read_entry(context, settings, function(message, entry)
        if message then
          return finish(message)
        end
        done(entry)
      end)
    end
    local function publish(before)
      read_entry(function(after)
        local desired = operation.entry or before
        if after.entry ~= "" and after.flags ~= desired.flags then
          return finish("Could not restore the file's index flags; refresh and retry")
        end
        if operation.entry and after.entry ~= operation.entry.entry then
          return finish("Could not restore the previous index entry; refresh and retry")
        end
        local function commit()
          local failure = operation.validate and operation.validate()
          if failure then
            return finish(failure)
          end
          local published, publish_error = uv.fs_rename(candidate, path)
          if not published then
            return finish("Could not publish the Git index: " .. tostring(publish_error))
          end
          finish(nil, before, after)
        end
        if not operation.head then
          return commit()
        end
        git.run(context.repo, { "rev-parse", "--verify", "--quiet", "HEAD" }, {}, function(revision)
          if revision.code ~= 0 and revision.code ~= 1 then
            return finish(git.error(revision))
          end
          local current = revision.code == 0 and vim.trim(revision.stdout) or false
          if current ~= (operation.head.revision or false) then
            return finish("HEAD changed while preparing the index action; refresh and retry")
          end
          git.run(context.repo, { "symbolic-ref", "--quiet", "HEAD" }, {}, function(reference)
            if reference.code ~= 0 and reference.code ~= 1 then
              return finish(git.error(reference))
            end
            local ref = reference.code == 0 and vim.trim(reference.stdout) or false
            if ref ~= operation.head.ref then
              return finish("The current branch changed while preparing the index action; refresh and retry")
            end
            commit()
          end)
        end)
      end)
    end
    local function flags(before)
      local desired = operation.entry or before
      read_entry(function(after)
        if after.entry == "" or after.flags == desired.flags then
          return publish(before)
        end
        local changes = {
          bit.band(desired.flags, 0x8000) ~= 0 and "--assume-unchanged" or "--no-assume-unchanged",
          bit.band(desired.flags, 0x40000000) ~= 0 and "--skip-worktree" or "--no-skip-worktree",
        }
        local function change(position)
          if not changes[position] then
            return publish(before)
          end
          run({ "update-index", changes[position], "--", context.path }, {}, function(result)
            if result.code ~= 0 then
              return finish(git.error(result))
            end
            change(position + 1)
          end)
        end
        change(1)
      end)
    end
    local function apply()
      read_entry(function(before)
        if not vim.deep_equal(before, expected) then
          return finish("The file's index entry changed; refresh and retry")
        end
        local arguments, options
        if operation.patch then
          arguments = { "apply", "--cached", "--whitespace=nowarn", "-" }
          options = { stdin = operation.patch }
        else
          local entry = operation.entry.entry
          if entry == "" then
            local oid = before.entry:match("^%d+ (%x+) ") or string.rep("0", 40)
            entry = "0 " .. string.rep("0", #oid) .. "\t" .. context.path .. "\0"
          end
          arguments = { "update-index", "-z", "--index-info" }
          options = { stdin = entry }
        end
        local function write()
          run(arguments, options, function(result)
            if result.code ~= 0 then
              return finish(git.error(result))
            end
            flags(before)
          end)
        end
        if operation.patch or operation.entry.entry == "" then
          return write()
        end
        local oid = operation.entry.entry:match("^%d+ (%x+) 0\t")
        local unavailable = "The previous staged blob is unavailable or unreadable; Undo Stage history was retained"
        if not oid then
          return finish(unavailable)
        end
        run({ "cat-file", "-t", oid }, {}, function(kind)
          if kind.code ~= 0 or vim.trim(kind.stdout) ~= "blob" then
            return finish(unavailable)
          end
          run({ "cat-file", "blob", oid }, { stdout = function() end }, function(blob)
            if blob.code ~= 0 then
              return finish(unavailable)
            end
            write()
          end)
        end)
      end)
    end
    if existing then
      apply()
    else
      run({ "read-tree", "--empty" }, {}, function(result)
        if result.code ~= 0 then
          return finish(git.error(result))
        end
        apply()
      end)
    end
  end)
end

return M
