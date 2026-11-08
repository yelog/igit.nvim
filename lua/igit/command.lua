local M = {}
local registered = false
local alias_owned = false
local alias_expression = "getcmdtype() ==# ':' && getcmdline() ==# 'igit' ? 'Igit' : 'igit'"
local panels = { "commit", "log", "push", "branch", "stash" }

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
    return vim.tbl_filter(function(panel)
      return panel:sub(1, #lead) == lead
    end, panels)
  end
  if arguments:match("^log%s+") then
    return vim.tbl_map(vim.fn.fnameescape, vim.fn.getcompletion(lead, "file"))
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
      if #args > 2 or (#args == 2 and args[1] ~= "log") then
        vim.notify("Usage: :Igit [commit|log|push|branch|stash]; :Igit log <file> (escape spaces with \\)",
          vim.log.levels.ERROR, { title = "igit.nvim" })
        return
      end
      require("igit").open(args[1], { file = args[2] })
    end, {
      nargs = "*",
      complete = M.complete,
      desc = "Open IGit or a panel; log accepts a file path",
    })
    vim.api.nvim_create_user_command("IgitClose", function()
      require("igit").close()
    end, { desc = "Hide the IGit window, keeping its terminal session alive" })
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
