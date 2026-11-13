# igit.nvim

Git tools in your editing buffers and the native [IGit](https://github.com/yelog/igit) terminal workspace inside Neovim. Stage hunk ranges and whole files, select hunks with a text object, read cached branch and change status, annotate files with blame, and open Git hosting links. Open Commit, Log, Push, Branch, Stash, or a file's native history in a floating window, a left/right/bottom split, or a tab.

Requires Neovim **0.10+** and Git. The editor features have no Lua dependencies and work without an IGit executable. Terminal panels and current-file diff additionally require a matching IGit build with panel, file-history, and diff command support; the plugin does not install it.

## Install

With lazy.nvim and the local checkout:

```lua
{
  dir = vim.fn.expand("~/workspace/vi/igit.nvim"),
  name = "igit.nvim",
  lazy = false, -- Also installs the interactive :igit abbreviation at startup.
  opts = {
    command = "igit",
    window = { layout = "float" },
  },
}
```

For terminal panels, install IGit separately and make sure `igit` is on Neovim's `PATH`. You can omit `command` because it defaults to `"igit"`. For a GitHub installation of the plugin, use `"yelog/igit.nvim"` instead of `dir` and `name`.

For Neovim's built-in package loader, put or symlink this checkout at `~/.local/share/nvim/site/pack/local/start/igit.nvim`, then optionally configure it in `init.lua`:

```lua
require("igit").setup()
```

No setup call is required for the defaults. Load at startup or on `BufReadPre` / `BufNewFile` to see hunk signs automatically. With command-only lazy loading, use `cmd = { "Igit", "IgitClose", "IgitDiff", "IgitBlame", "IgitInlineBlame", "IgitBrowse", "IgitNextHunk", "IgitPrevHunk", "IgitPreviewHunk", "IgitStageHunk", "IgitUnstageHunk", "IgitResetHunk", "IgitSelectHunk", "IgitStageFile", "IgitUnstageFile", "IgitResetFile" }` and uppercase commands for the first invocation; the lowercase abbreviation exists only after the plugin loads.

## Hunk signs and actions

Added, changed, and deleted lines appear in the sign column. Unsaved edits are
included. Staged changes have separate `IgitHunkStagedAdd`, `IgitHunkStagedChange`,
and `IgitHunkStagedDelete` highlights; unstaged signs take priority where they
overlap. Keep `signcolumn` enabled, for example `vim.opt.signcolumn = "yes"`.
Enable `termguicolors` to use the configured RGB colors.

The default colors follow IntelliJ IDEA's
[Dark editor gutter](https://github.com/JetBrains/intellij-community/blob/master/platform/platform-resources/src/themes/expUI/expUI_darkScheme.xml):
green `#549159` for additions, blue `#375FAD` for modifications, and gray
`#868A91` for deletions.

```lua
require("igit").setup({
  hunks = {
    enabled = true,
    debounce = 150,
    signs = { add = "│", change = "│", delete = "_" },
    colors = { add = "#549159", change = "#375FAD", delete = "#868A91" },
    staged_signs = true,
    priority = 6,
    max_file_size = 1024 * 1024,
  },
})
```

| Command | Action |
| --- | --- |
| `:Igit hunk next` / `:IgitNextHunk` | Next staged or unstaged hunk; wraps and accepts a mapping count. |
| `:Igit hunk prev` / `:IgitPrevHunk` | Previous staged or unstaged hunk. |
| `:Igit hunk preview` / `:IgitPreviewHunk` | Preview the hunk under the cursor in a read-only floating diff. |
| `:Igit hunk stage` / `:IgitStageHunk` | Stage the unstaged hunk under the cursor, including unsaved text. |
| `:Igit hunk unstage` / `:IgitUnstageHunk` | Restore only the staged hunk under the cursor to HEAD. |
| `:Igit hunk reset` / `:IgitResetHunk` | Restore the unstaged hunk to the index in the buffer; `u` undoes the reset. |
| `:Igit file stage` / `:IgitStageFile` | Stage the complete buffer contents for the current file. |
| `:Igit file unstage` / `:IgitUnstageFile` | Restore the current file's index entry to HEAD. |
| `:Igit file reset` / `:IgitResetFile` | Replace the buffer with the current index; disk and index are unchanged. |
| `:IgitSelectHunk` | Select the hunk under the cursor as a linewise Visual range. |

Actions use three distinct versions: HEAD, the real Git index, and the editing
buffer. Stage and unstage update the index without saving the buffer or changing
other staged files. Reset changes only the buffer; save normally to update disk.
Staged positions follow unsaved insertions and deletions above them.

The stage, unstage, and reset functions accept an optional line range. Visual
mappings can call them directly because the active selection is captured before
the asynchronous Git read. Ex ranges and Lua ranges are also supported:

```vim
:'<,'>Igit hunk stage
:20,28IgitResetHunk
```

```lua
require("igit").stage_hunk({ 20, 28 })
require("igit").unstage_hunk({ start = 20, finish = 28 })
```

Characterwise, linewise, and blockwise Visual selections all use their selected
line range. A partial addition inside a larger replacement is staged as an
addition rather than expanding to the whole hunk. Selecting every visible line
of a replacement applies that complete replacement, including old lines that
have no separately selectable buffer text. If unstaged deletions make a staged
range ambiguous, unstage rejects the operation instead of modifying unseen
lines. Deletion-only hunks have no buffer text to select; use cursor hunk
actions, preview, or the whole-file action for those.

Map the `ih` text object in Visual and Operator-pending modes to support
`vih`, `yih`, `dih`, and `cih`. The object is linewise and selects the unstaged
hunk first, then the staged hunk when no unstaged hunk covers the cursor.

```lua
vim.keymap.set({ "x", "o" }, "ih", function()
  require("igit").select_hunk()
end, { desc = "Select Git hunk" })
```

Updates are debounced, with Git index notifications and editor focus/save events
refreshing external changes. Binary files, unmerged entries, symlinks, and
submodules do not support hunk actions. Actions require UTF-8 files and reject
custom clean filters, `working-tree-encoding`, and `ident` attributes rather than bypassing
their conversions.
The default file limit is 1 MiB. File-only metadata changes, such as executable
bits, should be handled in the native Commit panel.

`:IgitPreviewHunk` and `:Igit hunk preview` reuse the current snapshot and never
run another Git command. `q` or `Esc` closes the preview without moving focus.

## Git status API

`require("igit").status(bufnr)` returns the cached status for a buffer without
running Git. The cache is updated asynchronously on buffer entry/save, Git index
and HEAD notifications, focus changes, and hunk refreshes. This keeps statusline
rendering synchronous and cheap.

```lua
local status = require("igit").status()
if status then
  print(status.branch, status.path)
  print(vim.inspect(status.unstaged))
  print(vim.inspect(status.staged))
end
```

The result includes `repo`, `root`, `gitdir`, `path`, `branch`, `head`, `oid`,
`detached`, `unborn`, `index_status`, `worktree_status`, `file_state`,
`untracked`, `ignored`, `conflicted`, `in_head`, `clean`, `modified`,
`staged_changes`, and `unstaged_changes`. `file_state` is one of `clean`,
`modified`, `added`, `ignored`, or `conflicted`. `unstaged` and `staged` each
contain `added`, `changed`, and `removed` counts; top-level `added`, `changed`,
and `removed` are the unstaged counts for compatibility with statusline
conventions. The line counts are published by the hunk engine; with
`hunks.enabled = false`, branch/path/file-state flags remain accurate and the
counts stay zero.

When the cache changes, the plugin emits `User IgitUpdated` with
`data.buf` and `data.status`. The separate event name is intentional:
`IgitChanged` triggers hunk rereads, while `IgitUpdated` reports completed status
reads. Non-repository buffers return `nil`. Unborn and detached HEADs are
represented explicitly rather than as empty branch names.

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "IgitUpdated",
  callback = function(event)
    -- Redraw only your statusline/tabline component here.
  end,
})
```

## File and inline blame

`:Igit blame` or `:IgitBlame` toggles a left annotation split with a date and author
for each line. Background colors distinguish age: `age1` is older than a year,
`age2` is within a year, `age3` within 90 days, `age4` within 30 days, and `age5`
within seven days. The annotation follows source scrolling and cursor movement.
Closing it restores the source window options.

`:Igit blame inline` or `:IgitInlineBlame` toggles current-line blame. EOL text is
the default placement. Both forms use the current buffer contents; uncommitted
lines display exactly `Uncommitted changes`.

```lua
require("igit").setup({
  blame = {
    inline = {
      enabled = true,
      position = "eol", -- "eol" or "statusline"
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
  },
})
```

Formats support `{author}`, `{date}`, `{summary}`, `{sha}` (eight characters),
and `{email}`. Dates use Lua's `os.date` format. Customize `IgitBlameInline` for
inline text, and `IgitBlameAge1` through `IgitBlameAge5` and
`IgitBlameUncommitted` for annotation backgrounds.

`file.width` defaults to `"auto"`, which uses the widest formatted annotation
row. Set it to a positive integer to use a fixed width.

For the bottom statusline, set `position = "statusline"` and add the component to
your existing statusline. The plugin preserves your statusline configuration:

```lua
vim.opt.statusline:append(" %{%v:lua.require'igit'.blame_statusline()%}")
```

For lualine, add `function() return require("igit").blame_statusline() end` as a
component. Blame results are cached for the buffer; cursor movement reuses them
without running Git again.

## Open in a browser

```vim
:Igit browse
:IgitBrowse
:10,20IgitBrowse
```

There is one browser action: open the current file on its Git hosting provider.
It uses the cursor line, or an Ex range when supplied, so the URL points directly
to that line or line range. There are no separate branch-only or file-only
commands.

Links use the current branch's upstream remote and remote branch when available,
then `origin` or the sole configured remote. Detached HEAD uses the commit hash.
GitHub, GitLab, and Bitbucket Cloud are supported with line anchors. Configure a
self-hosted server explicitly:

```lua
require("igit").setup({
  browse = {
    -- remote = "origin", -- Override automatic remote selection.
    hosts = { ["git.example.com"] = "gitlab" },
    -- open = function(url) ... end, -- Defaults to vim.ui.open.
  },
})
```

SSH and HTTP(S) remotes are normalized to browser URLs without credentials.
Paths, branch names, and line ranges are encoded for the selected provider.
GitHub and GitLab links include `?plain=1`, so rendered files such as Markdown
open in source view and the line anchor can select the requested line.
Links describe remote content: local unpushed changes and unsaved line numbers
may differ from the page in the browser. Browsing does not push anything.

## Editor mappings

No mappings are installed automatically. For example:

```lua
local igit = require("igit")
vim.keymap.set("n", "]h", igit.next_hunk, { desc = "Next Git hunk" })
vim.keymap.set("n", "[h", igit.prev_hunk, { desc = "Previous Git hunk" })
vim.keymap.set({ "n", "x" }, "<leader>hs", igit.stage_hunk, { desc = "Stage Git hunk or selection" })
vim.keymap.set({ "n", "x" }, "<leader>hu", igit.unstage_hunk, { desc = "Unstage Git hunk or selection" })
vim.keymap.set({ "n", "x" }, "<leader>hr", igit.reset_hunk, { desc = "Reset Git hunk or selection" })
vim.keymap.set({ "x", "o" }, "ih", igit.select_hunk, { desc = "Select Git hunk" })
vim.keymap.set("n", "<leader>hS", igit.stage_file, { desc = "Stage Git file" })
vim.keymap.set("n", "<leader>hU", igit.unstage_file, { desc = "Unstage Git file" })
vim.keymap.set("n", "<leader>hR", igit.reset_file, { desc = "Reset Git file" })
vim.keymap.set("n", "<leader>gb", igit.file_blame, { desc = "Git file blame" })
vim.keymap.set("n", "<leader>gB", igit.toggle_inline_blame, { desc = "Toggle inline blame" })
vim.keymap.set("n", "<leader>gd", igit.file_diff, { desc = "Diff current file with HEAD" })
vim.keymap.set("n", "<leader>gob", function() igit.browse() end, { desc = "Open current file in browser" })
```

## Terminal commands

```vim
:igit
:igit commit
:igit log
:igit push
:igit branch
:igit stash
:igit diff
:IgitDiff
:igit log %
:igit log src/main.rs
:igit log "src/a file.rs"
:IgitClose
```

`:Igit` is the actual Neovim command; `:igit` is a command-line abbreviation. It expands only when typed at the start of an Ex command, followed by a space or Enter. It does not alter search text or command arguments. Use `Igit` in mappings, scripts, `vim.cmd()`, or after command modifiers such as `silent`. An existing `igit` abbreviation is left intact.

Panel names and file paths support completion. A file path is accepted only after `log`; either quote paths with spaces or escape them with `\`. `%` means the file in the originating editor buffer, including when invoking another command from the IGit terminal. The buffer must have a file name. For a literal file named `%`, use `./%`.

IGit starts in the invoking window's current working directory, including `:lcd` or `:tcd`. It receives the file history target as `igit log -- <absolute-file-path>`. Saved file history comes from Git; unsaved editor changes are not passed to IGit. Use `:lcd` to change the workspace or pass `cwd` to the Lua API.

## Compare the current file with HEAD

`:Igit diff`, `:IgitDiff`, and `require("igit").file_diff()` open a side-by-side
native viewer for the current working file. It requires a matching native IGit
build. The buffer content, including unsaved edits, is written to a private
UTF-8 snapshot. The source cursor line is captured before the terminal opens and
passed to IGit as `diff --line <line> -- <absolute-file-path>`; the native
viewer centers that line initially.

```sh
igit diff --line 42 -- /absolute/path/to/file
```

The plugin sets `IGIT_DIFF_BUFFER` to the snapshot path. Native hunk restores
change only that snapshot. A restore can change its UTF-8 BOM or final-newline
state when it rebuilds the first or last hunk, including restoring an untracked
buffer to empty. The import accepts those changes, keeps the source's LF/CRLF
layout, and applies the resulting BOM/final-newline metadata. Without that
environment variable, native IGit edits the working file using its normal guards.

The viewer supports native `n`/`p` change navigation, `L` or Apply/`»` for the
current aligned group, `A` or All for the reviewed full restore, and `Tab` for
side switching, folding, and search. The current aligned group is marked in
both panes, and the toolbar reports its position. Press `u` or `U` to undo the
latest `L`/`A` restore while the viewer remains open; consecutive undos walk
backward through this session's restores. A successful `q`, `Esc`, or Close
exit, `:IgitClose`, or closing its window imports a changed snapshot into the
source buffer as one undoable change; source-buffer `u` and redo also restore
the imported BOM and final-newline metadata. The import never saves the buffer
and never stages content. If the source buffer was renamed, changed since the
snapshot was captured, lost, or has different encoding/line-ending settings,
the plugin does not overwrite it. Instead, the restored content is placed in a
listed recovery scratch buffer and a notification names it.

Each invocation creates a fresh snapshot and session, even when the same line is
diffed again, so reopening never reuses stale native state. Snapshot files are
private temporaries and are removed after import or abort. Reopening the diff
while the viewer is active first applies and closes the previous viewer.

File diff always uses a floating window, even when other IGit panels are
configured as splits or tabs. Configure its dimensions separately:

```lua
require("igit").setup({
  diff = {
    width = 0.95,  -- Fraction below 1, or an integer number of columns.
    height = 0.9,  -- Fraction below 1, or an integer number of rows.
    border = "rounded",
  },
})
```

`file_diff()` and `open("diff")` accept per-opening `window` overrides.
`layout` is always forced to `float`. The source file must be a named, loaded,
UTF-8 working buffer with LF or CRLF line endings and no binary content.

## Windows and sessions

```lua
require("igit").setup({
  command = "igit", -- Executable path, argv list, or resolver function (see below).
  command_alias = true,
  window = {
    layout = "float", -- "float", "left", "right", "bottom", "tab"
    border = "rounded", -- Floating windows only; accepts Neovim border values.
    -- width = 0.9,     -- Fraction below 1, or an integer number of columns.
    -- height = 0.85,   -- Fraction below 1, or an integer number of rows.
  },
  diff = {
    width = 0.95,      -- File diff is always a float.
    height = 0.9,
    border = "rounded",
  },
})
```

When omitted, floating windows use 90% of the available width and 85% of the height. Side splits use 50% of the width; bottom splits use 40% of the height. Tabs occupy the whole tab page. Floating windows and splits resize with the editor. Only the relevant dimension applies to a split.

Identical commands in the same working directory reuse their terminal session. Opening a different panel or file hides the old window and creates or resumes another session. This preserves drafts and running operations. `:IgitClose` or `require("igit").close()` hides the window and returns focus; the process keeps running. Reopen the same command to resume it, or use Neovim's buffer list. Use IGit's normal quit action to finish a session; a successful exit removes its terminal buffer. Failed processes leave their output available, report the exit code, and allow a fresh launch on the next invocation. `:bdelete!` explicitly stops and removes a terminal session. A current-file diff is the exception: hiding it imports any changed snapshot, ends the viewer process, and removes its temporary files.

Terminal input goes directly to IGit. Use Neovim's `<C-\><C-n>` to enter Terminal-Normal mode before running editor commands. The plugin does not replace IGit's Escape or `q` keys.

## Edit a working file from IGit

Highlight a file in Commit Changes and press `e` or `E`. With a matching native
IGit build, the plugin opens its working copy in the source Neovim window. An
already loaded buffer keeps unsaved edits. Floating IGit windows hide after the
file opens; splits stay visible and tab sessions stay open while focus returns
to the editor. The IGit process, drafts and checked files are retained. Reopen
the same command or use your normal IGit shortcut to return.

Save normally in Neovim. IGit's file watcher updates working-copy changes; the
Git index keeps its existing staged content until an explicit reviewed action.
Deleted files and submodule directories require an existing file target.
Neovim's normal modified-buffer guards apply: a blocked switch reports an error
and leaves the IGit window available. The bridge uses native terminal requests,
requires no RPC server, and does not launch another Neovim process. Both plugin
and executable must support this feature; standalone IGit uses Git's configured
external editor.

## Show a file at a revision

In a matching native IGit build, highlight a commit in File History and press `e`
to show the selected revision of the file. The buffer is listed and read-only,
with no file writes, swap file, undo file, or modifications to the current
working buffer. Its displayed title follows IDEA's form, for example
`user.ts (69028162)`, where the value is the first eight characters of the full
commit hash. The filetype and syntax are inferred from the original filename and
path. Homogeneous CRLF uses `fileformat=dos`; mixed line endings, missing final
newlines, and empty blobs retain their original bytes.

The buffer name includes the repository, historical path, and full revision.
Opening the same repository, path, and revision again reuses the buffer; another
revision gets a separate buffer. Existing buffers and unsaved text for the
working copy are retained. Missing paths, submodules, non-blob entries, binary
data, invalid UTF-8, and blobs larger than 512 KiB are rejected without replacing
the editor buffer. Floating IGit windows hide after the revision opens; splits
and tabs follow the same focus behavior as editing a working file.

### Revision request protocol

The plugin consumer listens for this terminal request:

```text
ESC ] 51 ; igit-show-revision ; JSON BEL
```

`JSON` contains `version` (`1`), `session` (the process's
`IGIT_NVIM_SESSION` token), `repo` (absolute repository path), `path` (relative
historical Git path), and `revision` (full 40- or 64-character hexadecimal
commit hash). The producer validates the blob as UTF-8, NUL-free, and at most
512 KiB before sending. The plugin additionally accepts only the active
terminal session and focused IGit window, then runs argv-based `git cat-file`
type, size, and blob queries without a shell. Foreign, malformed, stale, or
otherwise invalid requests are ignored or rejected without stealing focus.
Git reads use raw output with optional locks and lazy fetching disabled.

## Lua API and mappings

```lua
local igit = require("igit")

igit.open() -- Commit
igit.open("stash")
igit.open("diff")
igit.file_diff()
igit.open("log", { file = "%" })
igit.open("log", {
  file = "src/main.rs",
  cwd = "/path/to/workspace",
  window = { layout = "right", width = 70 },
})
igit.close()

igit.next_hunk()
igit.prev_hunk()
igit.preview_hunk()                 -- Cached floating hunk diff.
igit.stage_hunk()                  -- Cursor hunk.
igit.stage_hunk({ 10, 20 })        -- Selected buffer lines.
igit.unstage_file()                -- Current file only.
igit.reset_file()
igit.select_hunk()                 -- Linewise selection for ih mappings.
local status = igit.status()       -- Cached; never starts Git.

vim.keymap.set("n", "<leader>gg", function() igit.open() end, { desc = "IGit" })
vim.keymap.set("n", "<leader>gl", function()
  igit.open("log", { file = "%" })
end, { desc = "IGit file history" })
vim.keymap.set("n", "<leader>gd", igit.file_diff, { desc = "Diff current file with HEAD" })
```

`open(panel?, options?)` returns the terminal buffer number, or `nil, error` and a notification. `panel` defaults to `"commit"`; `"diff"` opens the current-file viewer. `options` supports `file`, `cwd`, and per-opening `window` overrides. `file_diff(options?)` is equivalent to `open("diff", options)`. Changing a layout reuses the same ordinary panel process; diff always starts a fresh one-shot viewer. `close()` returns whether a managed window was hidden. Calling `setup()` again replaces the configuration with the defaults plus the supplied options; existing jobs continue running.

The executable is launched with an argv list. To pass arguments to the installed `igit` command, configure `command` as a list:

```lua
require("igit").setup({
  command = { "igit", "--icons", "unicode" },
})
```

The panel and optional `-- <file>` are appended to this list. A string `command` is one executable path, so paths with spaces work without shell quoting. Use an absolute executable path when the editor changes directories.

`command` may also be a function returning an executable path or argv list. It is
called on every `open()`, before session lookup, and is not evaluated by `setup()`.
Return the resolved executable path to keep separate sessions for different builds:

```lua
require("igit").setup({
  command = function()
    local selected = vim.fn.expand("~/.local/state/igit/launcher/current")
    return assert(vim.uv.fs_realpath(selected), "Selected IGit executable is unavailable")
  end,
})
```

Resolver errors are reported without opening a terminal or stopping existing jobs.
Switching back to a previously used executable resumes its matching session. A
rebuild at the same path does not update an existing process; quit IGit normally
before opening it again to test the new build.

## Development

Run the dependency-free integration suite from this repository:

```sh
nvim --headless -u NONE -l tests/run.lua
nvim --headless -u NONE -l tests/hunks.lua
nvim --headless -u NONE -l tests/status.lua
nvim --headless -u NONE -l tests/blame.lua
nvim --headless -u NONE -l tests/browse.lua
nvim --headless -u NONE -l tests/editor.lua
nvim --headless -u NONE -l tests/file_diff.lua
```

The suite uses temporary files, local Git repositories, and fake terminal processes; it does not invoke real IGit or external services. It exercises real Neovim windows, asynchronous Git reads, command-line input, and session cleanup. The Neovim 0.10 API baseline is documented in the official [window and command APIs](https://github.com/neovim/neovim/blob/v0.10.4/runtime/doc/api.txt) and [terminal job functions](https://github.com/neovim/neovim/blob/v0.10.4/runtime/doc/builtin.txt). The included suite has been run on Neovim 0.12.4.

To exercise the real native viewer, point the additional smoke test at a freshly
built executable:

```sh
IGIT_NATIVE_BINARY=/absolute/path/to/igit nvim --headless -u NONE -l tests/native_file_diff.lua
```

It uses a disposable Git repository and checks centered source lines, hunk
navigation, in-viewer undo, restores, source-buffer undo/redo, empty files, BOM
and final-newline changes, and preservation of the working files, HEAD, and
real index.

The pre-existing editor suites also pass on Neovim 0.10.4. The new file-diff
suite was run on Neovim 0.12.4. On 0.10.4, the existing terminal suite's
20-column, 8-row floating-window case fails in both the original checkout and
this implementation.

See `:help igit.nvim` for the reference. Package managers usually generate help tags; for a manual installation, run `:helptags ALL` once.
