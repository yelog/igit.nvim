local M = {}
local cache = {}
local order = {}

local function identity(argv)
  local executable = vim.fn.exepath(argv[1])
  if executable == "" then
    executable = argv[1]
  end
  executable = vim.uv.fs_realpath(executable) or executable
  local stat = vim.uv.fs_stat(executable)
  return executable, vim.json.encode({
    executable, argv, stat and { stat.dev, stat.ino, stat.size, stat.mtime, stat.ctime } or false,
  })
end

function M.inspect(argv, cwd)
  local executable, key = identity(argv)
  if cache[key] then
    return cache[key]
  end
  local result = { executable = executable }
  local arguments = vim.deepcopy(argv)
  arguments[#arguments + 1] = "--capabilities"
  local started, process = pcall(vim.system, arguments, { cwd = cwd, text = true, timeout = 1000 })
  local waited, output = false, nil
  if started then
    waited, output = pcall(process.wait, process)
  end
  if not started or not waited or output.code ~= 0 then
    result.error = "IGit capability query failed or is unsupported. Update IGit and run :checkhealth igit."
  else
    local decoded, value = pcall(vim.json.decode, output.stdout or "")
    if not decoded or type(value) ~= "table" then
      result.error = "IGit returned invalid capability JSON. Update IGit and run :checkhealth igit."
    elseif value.schema_version ~= 1 then
      result.error = "Unsupported IGit capability schema " .. tostring(value.schema_version)
        .. "; expected 1. Update IGit or igit.nvim."
    elseif type(value.version) ~= "string" or value.version == "" or type(value.capabilities) ~= "table"
        or not vim.islist(value.capabilities) then
      result.error = "IGit returned an invalid capability contract. Update IGit and run :checkhealth igit."
    else
      result.version, result.editor_protocol = value.version, value.editor_protocol
      result.features = {}
      for _, feature in ipairs(value.capabilities) do
        if type(feature) ~= "string" or feature == "" then
          result.error = "IGit returned invalid capability names. Update IGit and run :checkhealth igit."
          break
        end
        result.features[feature] = true
      end
      result.schema_version = value.schema_version
    end
  end
  cache[key] = result
  order[#order + 1] = key
  if #order > 32 then
    cache[table.remove(order, 1)] = nil
  end
  return result
end

function M.check(result, feature)
  if not result or result.error then
    return nil, result and result.error or "IGit capabilities are unavailable. Run :checkhealth igit."
  end
  if not result.features or not result.features[feature] then
    return nil, "IGit " .. tostring(result.version) .. " does not support " .. feature
      .. ". Update IGit or choose another setup({ command = ... }); run :checkhealth igit."
  end
  if (feature == "editor" or feature == "revision" or feature == "repository-events")
      and result.editor_protocol ~= 1 then
    return nil, "Unsupported IGit editor protocol " .. tostring(result.editor_protocol)
      .. "; expected 1. Update IGit or igit.nvim; run :checkhealth igit."
  end
  return true
end

return M
