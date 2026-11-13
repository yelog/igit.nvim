local blame = {}
local api = vim.api

blame.defaults = {
  inline = {
    enabled = false,
    position = "eol",
    format = "{author}, {date}: {summary}",
    date_format = "%Y-%m-%d",
    delay = 250,
  },
  file = {
    format = "{date} {author}",
    date_format = "%Y/%m/%d",
    width = "auto",
  },
  colors = {
    age1 = "#252932",
    age2 = "#29354d",
    age3 = "#2d4266",
    age4 = "#315080",
    age5 = "#355e9b",
    uncommitted = "#574151",
  },
}

local color_groups = {
  age1 = "IgitBlameAge1",
  age2 = "IgitBlameAge2",
  age3 = "IgitBlameAge3",
  age4 = "IgitBlameAge4",
  age5 = "IgitBlameAge5",
  uncommitted = "IgitBlameUncommitted",
}

local configuration = vim.deepcopy(blame.defaults)
local states = {}
local annotation_states = {}
local namespace = api.nvim_create_namespace("igit.blame")
local initialized = false
local applied_highlights = {}
local request

local function buffer_loaded(buffer)
  return api.nvim_buf_is_valid(buffer) and api.nvim_buf_is_loaded(buffer)
end

local function sanitize_line(text)
  return tostring(text or ""):gsub("[%z\1-\31\127]", " ")
end

local function notify_error(message)
  vim.notify("Blame: " .. sanitize_line(message), vim.log.levels.ERROR, { title = "igit.nvim" })
end

local function cancel_timer(state)
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
end

local function invalidate(state)
  cancel_timer(state)
  state.generation = state.generation + 1
  state.cache = nil
  state.pending = nil
  state.error = nil
  state.error_tick = nil
  state.error_name = nil
  if buffer_loaded(state.buffer) then
    api.nvim_buf_clear_namespace(state.buffer, namespace, 0, -1)
  end
end

local function file_view_active(state)
  return state.file ~= nil
end

local function active(state)
  return state.inline or file_view_active(state)
end

local function get_state(buffer)
  if not states[buffer] then
    states[buffer] = {
      buffer = buffer,
      inline = configuration.inline.enabled,
      generation = 0,
    }
  end
  return states[buffer]
end

local function valid_file(buffer)
  if not buffer_loaded(buffer) or vim.bo[buffer].buftype ~= "" or api.nvim_buf_get_name(buffer) == "" then
    return nil, "The current buffer is not a named working file"
  end
  return true
end

local function set_highlight(name, color)
  local current = api.nvim_get_hl(0, { name = name, link = false })
  local previous = applied_highlights[name]
  if not next(current) or (previous and vim.deep_equal(current, previous)) then
    api.nvim_set_hl(0, name, { bg = color })
    applied_highlights[name] = api.nvim_get_hl(0, { name = name, link = false })
  end
end

local function define_highlights()
  for color_name, group_name in pairs(color_groups) do
    set_highlight(group_name, configuration.colors[color_name])
  end
  local inline_highlight = api.nvim_get_hl(0, { name = "IgitBlameInline", link = false })
  if not next(inline_highlight) then
    api.nvim_set_hl(0, "IgitBlameInline", { link = "Comment", default = true })
  end
end

local function uncommitted_entry()
  return {
    sha = string.rep("0", 40),
    author = "Uncommitted changes",
    summary = "Uncommitted changes",
    email = "",
    time = 0,
  }
end

local function parse_porcelain(text)
  local rows = {}
  local metadata_cache = {}
  local entry
  local final_line
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local sha, line_number = line:match("^(%x+) %d+ (%d+)")
    if sha and (#sha == 40 or #sha == 64) then
      final_line = tonumber(line_number)
      local cached = metadata_cache[sha]
      entry = cached and vim.deepcopy(cached) or { sha = sha }
    elseif entry then
      if line:sub(1, 1) == "\t" then
        metadata_cache[entry.sha] = vim.deepcopy(entry)
        rows[final_line] = entry.sha:match("^0+$") and uncommitted_entry() or entry
        entry = nil
        final_line = nil
      else
        local key, value = line:match("^(%S+) (.*)$")
        if key == "author" then
          entry.author = value
        elseif key == "author-mail" then
          entry.email = value:match("^<(.*)>$") or value
        elseif key == "author-time" then
          entry.time = tonumber(value)
        elseif key == "summary" then
          entry.summary = value
        end
      end
    end
  end
  return rows
end

local function format_date(timestamp, date_format)
  local success, date = pcall(os.date, date_format, timestamp or 0)
  return success and date or ""
end

local function expand_format(entry, template, date_format)
  if entry.sha:match("^0+$") then
    return "Uncommitted changes"
  end
  local values = {
    author = entry.author or "",
    date = format_date(entry.time, date_format),
    summary = entry.summary or "",
    sha = entry.sha:sub(1, 8),
    email = entry.email or "",
  }
  local output = {}
  local position = 1
  while position <= #template do
    local escaped = template:sub(position, position) == "\\"
    local start_position = escaped and position + 1 or position
    local match_start, match_end, key = template:find("{([%a_]+)}", start_position)
    if match_start == start_position then
      output[#output + 1] = escaped and template:sub(match_start, match_end)
        or (values[key] or template:sub(match_start, match_end))
      position = match_end + 1
    elseif template:sub(position, position + 1) == "{{" then
      local ending = template:find("}}", position + 2, true)
      if ending then
        output[#output + 1] = template:sub(position + 1, ending)
        position = ending + 2
      else
        output[#output + 1] = template:sub(position, position)
        position = position + 1
      end
    else
      output[#output + 1] = template:sub(position, position)
      position = position + 1
    end
  end
  return sanitize_line(table.concat(output))
end

local function recency_group(entry)
  if entry.sha:match("^0+$") then
    return "IgitBlameUncommitted"
  end
  local days = math.max(0, os.time() - (entry.time or 0)) / 86400
  if days <= 7 then
    return "IgitBlameAge5"
  elseif days <= 30 then
    return "IgitBlameAge4"
  elseif days <= 90 then
    return "IgitBlameAge3"
  elseif days <= 365 then
    return "IgitBlameAge2"
  end
  return "IgitBlameAge1"
end

local function fit_width(text, width)
  local result = ""
  local characters = vim.fn.split(text, "\\zs")
  for character_index = 1, #characters do
    local character = characters[character_index]
    if vim.fn.strdisplaywidth(result .. character) > width then
      break
    end
    result = result .. character
  end
  return result .. string.rep(" ", math.max(0, width - vim.fn.strdisplaywidth(result)))
end

local function file_text_width(state, format, date_format)
  local width = 1
  if state.cache then
    for _, entry in ipairs(state.cache.rows) do
      width = math.max(width, vim.fn.strdisplaywidth(expand_format(entry, format, date_format)))
    end
  end
  return width
end

local function resolved_file_width(text_width, available_width)
  local width = configuration.file.width == "auto" and text_width or configuration.file.width
  return math.max(1, math.min(width, math.max(1, available_width or vim.o.columns - 2)))
end

local function set_file_width(state, width)
  local view = state.file
  if not view or not api.nvim_win_is_valid(view.window) then
    return width
  end
  if api.nvim_win_get_width(view.window) ~= width then
    pcall(api.nvim_win_set_width, view.window, width)
  end
  return api.nvim_win_get_width(view.window)
end

local function cache_current(state)
  return state.cache
    and buffer_loaded(state.buffer)
    and state.cache.tick == api.nvim_buf_get_changedtick(state.buffer)
    and state.cache.name == api.nvim_buf_get_name(state.buffer)
end

local function source_window(buffer)
  local current_window = api.nvim_get_current_win()
  if api.nvim_win_is_valid(current_window) and api.nvim_win_get_buf(current_window) == buffer then
    return current_window
  end
  local window = vim.fn.bufwinid(buffer)
  if window ~= -1 and api.nvim_win_is_valid(window) then
    return window
  end
end

local function render_inline(state)
  if not buffer_loaded(state.buffer) then
    return
  end
  api.nvim_buf_clear_namespace(state.buffer, namespace, 0, -1)
  if not cache_current(state)
    or not state.inline
    or configuration.inline.position ~= "eol"
  then
    return
  end
  local window = source_window(state.buffer)
  if not window then
    return
  end
  local row = api.nvim_win_get_cursor(window)[1] - 1
  local entry = state.cache.rows[row + 1]
  if not entry then
    return
  end
  api.nvim_buf_set_extmark(state.buffer, namespace, row, 0, {
    virt_text = {
      {
        expand_format(entry, configuration.inline.format, configuration.inline.date_format),
        "IgitBlameInline",
      },
    },
    virt_text_pos = "eol",
  })
end

local function sync_file_view(state)
  local view = state.file
  if not view
    or not api.nvim_win_is_valid(view.source)
    or not api.nvim_win_is_valid(view.window)
    or not buffer_loaded(view.buffer)
  then
    return
  end
  local source_cursor = api.nvim_win_get_cursor(view.source)
  local line_count = api.nvim_buf_line_count(view.buffer)
  api.nvim_win_set_cursor(view.window, {
    math.min(source_cursor[1], math.max(1, line_count)),
    0,
  })
  local source_view = api.nvim_win_call(view.source, vim.fn.winsaveview)
  api.nvim_win_call(view.window, function()
    vim.fn.winrestview({
      topline = source_view.topline,
      topfill = source_view.topfill,
      leftcol = 0,
    })
  end)
end

local function render_file(state)
  local view = state.file
  if not view
    or not buffer_loaded(view.buffer)
    or not api.nvim_win_is_valid(view.window)
  then
    return
  end
  local signature = table.concat({
    configuration.file.format,
    configuration.file.date_format,
    tostring(configuration.file.width),
  }, "\0")
  if view.rendered_cache == state.cache and view.rendered_signature == signature then
    sync_file_view(state)
    return
  end
  local width = set_file_width(
    state,
    resolved_file_width(
      file_text_width(state, configuration.file.format, configuration.file.date_format),
      view.max_width
    )
  )
  local lines = {}
  for index, entry in ipairs(state.cache.rows) do
    lines[index] = fit_width(
      expand_format(entry, configuration.file.format, configuration.file.date_format),
      width
    )
  end
  vim.bo[view.buffer].modifiable = true
  api.nvim_buf_set_lines(view.buffer, 0, -1, false, lines)
  vim.bo[view.buffer].modifiable = false
  api.nvim_buf_clear_namespace(view.buffer, namespace, 0, -1)
  for index, entry in ipairs(state.cache.rows) do
    local group = recency_group(entry)
    api.nvim_buf_set_extmark(view.buffer, namespace, index - 1, 0, {
      hl_group = group,
      end_col = #lines[index],
      line_hl_group = group,
      hl_eol = true,
    })
  end
  view.rendered_cache = state.cache
  view.rendered_signature = signature
  sync_file_view(state)
end

local function render(state)
  if not cache_current(state) then
    return
  end
  render_inline(state)
  render_file(state)
end

local function restore_window_options(view)
  if not api.nvim_win_is_valid(view.source) then
    return
  end
  for option, value in pairs(view.saved_options) do
    pcall(api.nvim_set_option_value, option, value, { win = view.source })
  end
end

local function close_file_view(state, window_closed, buffer_closed)
  local view = state.file
  if not view then
    return false
  end
  state.file = nil
  annotation_states[view.buffer] = nil
  restore_window_options(view)
  if not (state.inline and cache_current(state)) then
    invalidate(state)
  end
  if not window_closed and api.nvim_win_is_valid(view.window) then
    pcall(api.nvim_win_close, view.window, true)
  end
  if not buffer_closed and api.nvim_buf_is_valid(view.buffer) then
    pcall(api.nvim_buf_delete, view.buffer, { force = true })
  end
  if state.inline then
    render_inline(state)
    if not cache_current(state) then
      request(state, true)
    end
  end
  return true
end

local function dispose_state(state)
  state.inline = false
  close_file_view(state, false, false)
  invalidate(state)
  states[state.buffer] = nil
end

local function complete_blame(state, rows)
  local line_count = api.nvim_buf_line_count(state.buffer)
  for line_number = 1, line_count do
    if not rows[line_number] then
      return nil, "Incomplete Git blame output"
    end
  end
  state.cache = {
    rows = rows,
    tick = api.nvim_buf_get_changedtick(state.buffer),
    name = api.nvim_buf_get_name(state.buffer),
    repo = state.context.repo,
    path = state.context.path,
  }
  state.pending = nil
  state.error = nil
  render(state)
  return true
end

request = function(state, immediate)
  if not buffer_loaded(state.buffer) or not active(state) then
    return
  end
  if cache_current(state) then
    render(state)
    return
  end
  local current_tick = api.nvim_buf_get_changedtick(state.buffer)
  local current_name = api.nvim_buf_get_name(state.buffer)
  if state.error and state.error_tick == current_tick and state.error_name == current_name then
    return
  end
  if state.pending then
    if state.pending.generation == state.generation
      and state.pending.tick == current_tick
      and state.pending.name == current_name
    then
      return
    end
    invalidate(state)
  end
  cancel_timer(state)
  local scheduled_generation = state.generation
  local function read()
    if states[state.buffer] ~= state or state.generation ~= scheduled_generation then
      return
    end
    cancel_timer(state)
    if not buffer_loaded(state.buffer) or not active(state) then
      return
    end
    local generation = state.generation
    local tick = api.nvim_buf_get_changedtick(state.buffer)
    local name = api.nvim_buf_get_name(state.buffer)
    local pending = {
      generation = generation,
      tick = tick,
      name = name,
    }
    state.pending = pending
    local function release_pending()
      if state.pending == pending then
        state.pending = nil
      end
    end
    local function still_current()
      return states[state.buffer] == state
        and state.generation == generation
        and buffer_loaded(state.buffer)
        and active(state)
        and api.nvim_buf_get_changedtick(state.buffer) == tick
        and api.nvim_buf_get_name(state.buffer) == name
    end
    local function current()
      if still_current() then
        return true
      end
      release_pending()
      return false
    end
    local function fail(message)
      if not current() then
        return
      end
      release_pending()
      state.error = message
      state.error_tick = tick
      state.error_name = name
      notify_error(message)
    end
    local git_loaded, git = pcall(require, "igit.git")
    if not git_loaded then
      fail("Git integration is unavailable: " .. tostring(git))
      return
    end
    local text = git.text(state.buffer)
    if vim.bo[state.buffer].fileformat == "dos" then
      text = text:gsub("\n", "\r\n")
    end
    local function use_uncommitted()
      local rows = {}
      for line_number = 1, api.nvim_buf_line_count(state.buffer) do
        rows[line_number] = uncommitted_entry()
      end
      local completed, message = complete_blame(state, rows)
      if not completed then
        fail(message)
      end
    end
    git.context(state.buffer, function(context_error, context)
      if not current() then
        return
      end
      if context_error then
        fail(context_error)
        return
      end
      state.context = context
      git.run(context.repo, {
        "blame",
        "--line-porcelain",
        "--contents",
        "-",
        "--",
        context.path,
      }, { stdin = text }, function(result)
        if not current() then
          return
        end
        if result.code == 0 then
          if result.stdout == "" and text == "" then
            use_uncommitted()
            return
          end
          local completed, message = complete_blame(state, parse_porcelain(result.stdout or ""))
          if not completed then
            fail(message)
          end
          return
        end
        git.run(context.repo, {
          "ls-tree",
          "-z",
          "HEAD",
          "--",
          context.path,
        }, {}, function(tree)
          if not current() then
            return
          end
          if tree.code == 0 then
            if tree.stdout == "" then
              use_uncommitted()
            else
              fail(git.error(result))
            end
            return
          end
          git.run(context.repo, { "rev-parse", "--verify", "--quiet", "HEAD" }, {}, function(head)
            if not current() then
              return
            end
            if head.code == 1 and (head.stderr or "") == "" then
              git.run(context.repo, { "symbolic-ref", "-q", "HEAD" }, {}, function(reference)
                if not current() then
                  return
                end
                if reference.code == 0 and reference.stdout ~= "" then
                  use_uncommitted()
                else
                  fail(git.error(result))
                end
              end)
            else
              fail(git.error(result))
            end
          end)
        end)
      end)
    end)
  end
  if immediate or configuration.inline.delay == 0 then
    read()
  else
    state.timer = vim.uv.new_timer()
    state.timer:start(configuration.inline.delay, 0, vim.schedule_wrap(read))
  end
end

local function refresh_cursor(buffer)
  if not valid_file(buffer) then
    return
  end
  local state = get_state(buffer)
  local view = state.file
  if view and (not api.nvim_win_is_valid(view.source) or api.nvim_win_get_buf(view.source) ~= buffer) then
    close_file_view(state, false, false)
  end
  if cache_current(state) then
    if state.inline and configuration.inline.position == "eol" then
      render_inline(state)
    end
    if state.file then
      sync_file_view(state)
    end
  elseif active(state) then
    request(state, false)
  end
end

local function invalidate_buffer(buffer)
  local state = states[buffer]
  if not state then
    return
  end
  invalidate(state)
  if active(state) then
    request(state, false)
  end
end

local function invalidate_active()
  for buffer, state in pairs(states) do
    if active(state) then
      invalidate(state)
      request(state, false)
    end
  end
end

function blame.refresh(buffer)
  buffer = (buffer == nil or buffer == 0) and api.nvim_get_current_buf() or buffer
  local state = states[buffer]
  if not state then
    return
  end
  invalidate(state)
  if active(state) then
    request(state, true)
  end
end

function blame.statusline(buffer)
  buffer = (buffer == nil or buffer == 0) and api.nvim_get_current_buf() or buffer
  local state = states[buffer]
  if not state
    or not state.inline
    or configuration.inline.position ~= "statusline"
    or not cache_current(state)
  then
    return ""
  end
  local window = source_window(buffer)
  if not window then
    return ""
  end
  local entry = state.cache.rows[api.nvim_win_get_cursor(window)[1]]
  if not entry then
    return ""
  end
  local text = expand_format(entry, configuration.inline.format, configuration.inline.date_format)
  return (text:gsub("%%", "%%%%"))
end

local function ensure_setup()
  if not initialized then
    blame.setup()
  end
end

function blame.toggle_inline_blame()
  ensure_setup()
  local buffer = api.nvim_get_current_buf()
  local valid, message = valid_file(buffer)
  if not valid then
    return nil, message
  end
  local state = get_state(buffer)
  state.inline = not state.inline
  if state.inline then
    if cache_current(state) then
      render_inline(state)
    else
      request(state, true)
    end
  else
    render_inline(state)
    if not active(state) then
      invalidate(state)
    end
  end
  return state.inline
end

local function file_view_for_buffer(buffer)
  local state = annotation_states[buffer] or states[buffer]
  if state and state.file then
    return state
  end
end

function blame.file_blame()
  ensure_setup()
  local buffer = api.nvim_get_current_buf()
  local existing = file_view_for_buffer(buffer)
  if existing then
    close_file_view(existing, false, false)
    return false
  end
  local valid, message = valid_file(buffer)
  if not valid then
    return nil, message
  end
  local state = get_state(buffer)
  local source = api.nvim_get_current_win()
  local view = {
    source = source,
    buffer = api.nvim_create_buf(false, true),
    saved_options = {},
    max_width = math.max(1, api.nvim_win_get_width(source) - 2),
  }
  state.file = view
  annotation_states[view.buffer] = state
  local success, failure = pcall(function()
    vim.bo[view.buffer].buftype = "nofile"
    vim.bo[view.buffer].bufhidden = "wipe"
    vim.bo[view.buffer].swapfile = false
    vim.bo[view.buffer].undofile = false
    vim.bo[view.buffer].buflisted = false
    vim.bo[view.buffer].filetype = "igitblame"
    api.nvim_buf_set_name(view.buffer, "igit://blame/" .. buffer .. "/" .. view.buffer)
    api.nvim_buf_set_lines(
      view.buffer,
      0,
      -1,
      false,
      vim.fn["repeat"]({ "" }, api.nvim_buf_line_count(buffer))
    )
    vim.bo[view.buffer].modifiable = false
    vim.bo[view.buffer].readonly = true
    view.window = api.nvim_open_win(view.buffer, false, {
      split = "left",
      win = source,
      width = resolved_file_width(
        file_text_width(state, configuration.file.format, configuration.file.date_format),
        view.max_width
      ),
    })
    for option, value in pairs({
      wrap = false,
      foldenable = false,
      diff = false,
      smoothscroll = false,
    }) do
      view.saved_options[option] = api.nvim_get_option_value(option, { win = source })
      api.nvim_set_option_value(option, value, { win = source })
      api.nvim_set_option_value(option, value, { win = view.window })
    end
    for option, value in pairs({
      number = false,
      relativenumber = false,
      signcolumn = "no",
      foldcolumn = "0",
      winfixwidth = true,
      list = false,
      scrollbind = false,
      cursorbind = false,
    }) do
      api.nvim_set_option_value(option, value, { win = view.window })
    end
    request(state, true)
  end)
  if not success then
    close_file_view(state, false, false)
    return nil, tostring(failure)
  end
  return true
end

local function validate_options(value, defaults, path)
  assert(type(value) == "table", "igit.blame: " .. path .. " must be a table")
  for key, item in pairs(value) do
    local default = defaults[key]
    assert(default ~= nil, "igit.blame: unknown option " .. path .. key)
    if path == "file." and key == "width" then
      assert(
        item == "auto" or (type(item) == "number" and item >= 1 and item < math.huge and item % 1 == 0),
        "igit.nvim: blame file.width must be 'auto' or a positive integer"
      )
    elseif type(default) == "table" then
      validate_options(item, default, path .. key .. ".")
    else
      assert(type(item) == type(default), "igit.blame: invalid type for " .. path .. key)
    end
  end
end

local function validate_configuration(candidate)
  assert(
    candidate.inline.position == "eol" or candidate.inline.position == "statusline",
    "igit.blame: invalid inline.position"
  )
  assert(
    candidate.inline.delay >= 0
      and candidate.inline.delay < math.huge
      and candidate.inline.delay % 1 == 0,
    "igit.blame: delay must be a nonnegative integer"
  )
  assert(candidate.file.width == "auto"
      or (candidate.file.width >= 1
        and candidate.file.width < math.huge
        and candidate.file.width % 1 == 0),
    "igit.blame: width must be 'auto' or a positive integer")
  assert(candidate.inline.format ~= "" and candidate.file.format ~= "", "igit.blame: format must not be empty")
  for section_index = 1, 2 do
    local section = ({ candidate.inline, candidate.file })[section_index]
    assert(
      section.date_format ~= ""
        and not section.date_format:find("%z")
        and pcall(os.date, section.date_format, 0),
      "igit.blame: invalid date_format"
    )
  end
  for color_name, color in pairs(candidate.colors) do
    assert(color:match("^#%x%x%x%x%x%x$"), "igit.blame: colors must be #RRGGBB")
  end
end

local function configure_autocmds()
  local group = api.nvim_create_augroup("IgitBlame", { clear = true })
  api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = define_highlights,
  })
  api.nvim_create_autocmd({ "BufDelete", "BufWipeout", "BufUnload" }, {
    group = group,
    callback = function(event)
      local buffer = event.buf
      local state = states[buffer]
      if state then
        vim.schedule(function()
          if states[state.buffer] == state then
            dispose_state(state)
          end
        end)
        return
      end
      local owner = annotation_states[buffer]
      if owner then
        vim.schedule(function()
          if owner.file and owner.file.buffer == buffer then
            close_file_view(owner, false, true)
          end
        end)
      end
    end,
  })
  api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(event)
      local closed_window = tonumber(event.match)
      vim.schedule(function()
        for buffer, state in pairs(states) do
          local view = state.file
          if view and view.window == closed_window then
            close_file_view(state, true, false)
          elseif view and view.source == closed_window then
            close_file_view(state, false, false)
          end
        end
      end)
    end,
  })
  api.nvim_create_autocmd({
    "TextChanged",
    "TextChangedI",
    "TextChangedP",
    "BufFilePost",
    "BufWritePost",
  }, {
    group = group,
    callback = function(event)
      invalidate_buffer(event.buf)
    end,
  })
  api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = invalidate_active,
  })
  api.nvim_create_autocmd("WinScrolled", {
    group = group,
    callback = function(event)
      local window = tonumber(event.match)
      if not window then
        return
      end
      for _, state in pairs(states) do
        if state.file and state.file.source == window then
          sync_file_view(state)
        end
      end
    end,
  })
  api.nvim_create_autocmd("ShellCmdPost", {
    group = group,
    callback = invalidate_active,
  })
  api.nvim_create_autocmd({
    "BufReadPost",
    "BufNewFile",
    "BufEnter",
    "BufWinEnter",
    "CursorMoved",
    "CursorMovedI",
  }, {
    group = group,
    callback = function(event)
      refresh_cursor(event.buf)
    end,
  })
  api.nvim_create_autocmd("BufWinLeave", {
    group = group,
    callback = function(event)
      local state = states[event.buf]
      if state and state.file and api.nvim_get_current_win() == state.file.source then
        close_file_view(state, false, false)
      end
    end,
  })
  api.nvim_create_autocmd("User", {
    group = group,
    pattern = "IgitChanged",
    callback = function(event)
      local data = type(event.data) == "table" and event.data or {}
      for buffer, state in pairs(states) do
        if data.buf == buffer
          or (data.repo and state.context and data.repo == state.context.repo)
          or (not data.buf and not data.repo)
        then
          blame.refresh(buffer)
        end
      end
    end,
  })
end

function blame.setup(options)
  assert(vim.fn.has("nvim-0.10") == 1, "igit.blame requires Neovim 0.10 or newer")
  assert(options == nil or type(options) == "table", "igit.blame: options must be a table")
  validate_options(options or {}, blame.defaults, "")
  local previous = configuration
  local candidate = vim.tbl_deep_extend("force", vim.deepcopy(blame.defaults), options or {})
  validate_configuration(candidate)
  local changed = not vim.deep_equal(previous, candidate)
  configuration = candidate
  initialized = true
  define_highlights()
  configure_autocmds()
  if changed then
    local inline_default_changed = previous.inline.enabled ~= candidate.inline.enabled
    for buffer, state in pairs(states) do
      if inline_default_changed then
        state.inline = candidate.inline.enabled
      end
      if state.file
        and not (buffer_loaded(state.file.buffer) and api.nvim_win_is_valid(state.file.window))
      then
        close_file_view(state, false, false)
      end
      if state.file then
        set_file_width(
          state,
          resolved_file_width(
            file_text_width(state, candidate.file.format, candidate.file.date_format),
            state.file.max_width
          )
        )
      end
      if not active(state) then
        invalidate(state)
      elseif cache_current(state) then
        render(state)
      else
        request(state, false)
      end
    end
  end
  local buffer = api.nvim_get_current_buf()
  if valid_file(buffer) then
    local state = get_state(buffer)
    if configuration.inline.enabled and not cache_current(state) and not state.pending then
      request(state, false)
    end
  end
end

return blame
