local M = {}

function M.check()
  local health = vim.health
  health.start("igit.nvim")
  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("Neovim 0.10 or newer is required")
  end
  local git = vim.fn.exepath("git")
  if git == "" then
    health.error("Git executable not found on PATH")
  else
    health.ok("Git executable: " .. git)
  end
  local argv, command_error = require("igit")._command()
  if not argv then
    health.error(command_error)
    return
  end
  local result = require("igit.capabilities").inspect(argv, vim.fn.getcwd())
  health.info("IGit executable: " .. result.executable)
  if result.error then
    health.warn(result.error)
    health.info("Ordinary TUI panels can still start. Editor Git features do not require native IGit.")
    return
  end
  health.ok("IGit version: " .. result.version .. "; capability schema: " .. result.schema_version)
  health.info("Editor protocol: " .. tostring(result.editor_protocol) .. " (expected 1)")
  for _, feature in ipairs({ "editor", "revision", "file-diff", "repository-events" }) do
    local supported, message = require("igit.capabilities").check(result, feature)
    if supported then
      health.ok("Supported: " .. feature)
    else
      health.warn(message)
    end
  end
end

return M
