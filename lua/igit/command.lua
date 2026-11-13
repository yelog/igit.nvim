local M = {}
local registered = false
local alias_owned = false
local alias_expression = "getcmdtype() ==# ':' && getcmdline() ==# 'igit' ? 'Igit' : 'igit'"
local panels = { "commit", "log", "push", "branch", "stash", "diff", "hunk", "file", "blame", "browse" }
local actions = {
  hunk = { "next", "prev", "preview", "stage", "unstage", "reset" },
  file = { "stage", "unstage", "reset" },
  blame = { "file", "inline" },
}

local function filter(choices, lead)
  return vim.tbl_filter(function(choice)
    return choice:sub(1, #lead) == lead
  end, choices)
end

local function editor_command(args, command)
  local kind = args[1]
  if kind == "diff" then
    if #args > 1 then
      vim.notify("Usage: :Igit diff", vim.log.levels.ERROR, { title = "igit.nvim" })
    else
      require("igit").file_diff()
    end
    return true
  end
  if kind == "browse" then
    if #args > 1 then
      vim.notify("Usage: :Igit browse", vim.log.levels.ERROR, { title = "igit.nvim" })
    else
      local options = command.range > 0 and { line = command.line1, end_line = command.line2 } or {}
      require("igit").browse(options)
    end
    return true
  end
  if not actions[kind] then
    return false
  end
  local action = args[2] or (kind == "blame" and "file" or kind == "file" and "stage" or "next")
  if #args > 2 or not vim.tbl_contains(actions[kind], action) then
    vim.notify("Usage: :Igit " .. kind .. " [" .. table.concat(actions[kind], "|") .. "]",
      vim.log.levels.ERROR, { title = "igit.nvim" })
    return true
  end
  local igit = require("igit")
  if kind == "blame" then
    if action == "file" then
      igit.file_blame()
    else
      igit.toggle_inline_blame()
    end
  elseif kind == "file" then
    local methods = { stage = "stage_file", unstage = "unstage_file", reset = "reset_file" }
    igit[methods[action]]()
  else
    local methods = {
      next = "next_hunk", prev = "prev_hunk", preview = "preview_hunk",
      stage = "stage_hunk", unstage = "unstage_hunk", reset = "reset_hunk",
    }
    local range = command.range > 0 and { command.line1, command.line2 } or nil
    igit[methods[action]](range)
  end
  return true
end

-- Ex user-command fargs only unescape whitespace and backslashes. Parse the
-- original text so paths produced by fnameescape() also keep $, %, #, etc.
local function parse(arguments)
  local result, token = {}, {}
  local quote, started
  local i = 1
  while i <= #arguments do
    local char = arguments:sub(i, i)
    local next_char = arguments:sub(i + 1, i + 1)
    if char == "\\" and next_char ~= "" and next_char:find("[%s\\\"'|!<%[%]{}$`#%%*?]") then
      token[#token + 1] = next_char
      started = true
      i = i + 1
    elseif quote then
      if char == quote then
        quote = nil
      else
        token[#token + 1] = char
      end
    elseif char == "'" or char == '"' then
      quote, started = char, true
    elseif char:match("%s") then
      if started then
        result[#result + 1] = table.concat(token)
        token, started = {}, false
      end
    else
      token[#token + 1] = char
      started = true
    end
    i = i + 1
  end
  if quote then
    return nil, "Unclosed quote in IGit file path"
  end
  if started then
    result[#result + 1] = table.concat(token)
  end
  return result
end

function M.complete(lead, line, position)
  local before_cursor = line:sub(1, position)
  local arguments = before_cursor:match("%f[%w]Igit%s+(.*)$") or ""
  if not arguments:find("%s") then
    return filter(panels, lead)
  end
  if arguments:match("^log%s+") then
    return vim.tbl_map(vim.fn.fnameescape, vim.fn.getcompletion(lead, "file"))
  end
  local kind = arguments:match("^(%S+)%s+")
  if actions[kind] then
    return filter(actions[kind], lead)
  end
  return {}
end

function M.register(enable_alias)
  if not registered then
    vim.api.nvim_create_user_command("Igit", function(command)
      local args, parse_error = parse(command.args)
      if not args then
        vim.notify(parse_error, vim.log.levels.ERROR, { title = "igit.nvim" })
        return
      end
      if editor_command(args, command) then
        return
      end
      if #args > 2 or (#args == 2 and args[1] ~= "log") then
        vim.notify("Usage: :Igit [commit|log|push|branch|stash|diff|hunk|file|blame|browse]; :Igit log <file> (escape spaces with \\)",
          vim.log.levels.ERROR, { title = "igit.nvim" })
        return
      end
      require("igit").open(args[1], { file = args[2] })
    end, {
      nargs = "*",
      range = true,
      complete = M.complete,
      desc = "Open IGit or a panel; log accepts a file path",
    })
    vim.api.nvim_create_user_command("IgitClose", function()
      require("igit").close()
    end, { desc = "Hide IGit; finalize a current-file diff" })
    vim.api.nvim_create_user_command("IgitDiff", function()
      require("igit").file_diff()
    end, { desc = "Diff the current file against HEAD" })
    for suffix, method in pairs({
      NextHunk = "next_hunk", PrevHunk = "prev_hunk", StageHunk = "stage_hunk",
      UnstageHunk = "unstage_hunk", ResetHunk = "reset_hunk", PreviewHunk = "preview_hunk",
      SelectHunk = "select_hunk",
    }) do
      vim.api.nvim_create_user_command("Igit" .. suffix, function(command)
        local range = command.range > 0 and { command.line1, command.line2 } or nil
        require("igit")[method](range)
      end, { range = true, desc = "IGit " .. method:gsub("_", " ") })
    end
    for suffix, method in pairs({
      StageFile = "stage_file", UnstageFile = "unstage_file", ResetFile = "reset_file",
      Blame = "file_blame", InlineBlame = "toggle_inline_blame",
    }) do
      vim.api.nvim_create_user_command("Igit" .. suffix, function()
        require("igit")[method]()
      end, { desc = "IGit " .. method:gsub("_", " ") })
    end
    vim.api.nvim_create_user_command("IgitBrowse", function(command)
      local options = command.range > 0 and { line = command.line1, end_line = command.line2 } or {}
      require("igit").browse(options)
    end, {
      nargs = 0,
      range = true,
      desc = "Open the current file on its Git host at the cursor line or range",
    })
    registered = true
  end
  local existing = vim.fn.maparg("igit", "c", true, true)
  if enable_alias and vim.tbl_isempty(existing) then
    vim.cmd("cnoreabbrev <expr> igit " .. alias_expression)
    alias_owned = true
  elseif not enable_alias and alias_owned then
    if existing.rhs == alias_expression then
      vim.cmd("cunabbrev igit")
    end
    alias_owned = false
  end
end

return M
