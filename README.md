# igit.nvim

Run the native [IGit](https://github.com/yelog/igit) terminal workspace inside Neovim. Open Commit, Log, Push, Branch, Stash, or a file's native history in a floating window, a left/right/bottom split, or a tab.

Requires Neovim **0.10+** and an IGit executable with panel and file-history command support. The plugin has no Lua dependencies and does not install IGit.

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

Install IGit separately and make sure `igit` is on Neovim's `PATH`. You can omit `command` because it defaults to `"igit"`. For a GitHub installation of the plugin, use `"yelog/igit.nvim"` instead of `dir` and `name`.

For Neovim's built-in package loader, put or symlink this checkout at `~/.local/share/nvim/site/pack/local/start/igit.nvim`, then optionally configure it in `init.lua`:

```lua
require("igit").setup()
```

No setup call is required for the defaults. With lazy loading, use `cmd = { "Igit", "IgitClose" }` and use uppercase `:Igit` for the first invocation; the lowercase abbreviation exists only after the plugin loads.

## Commands

```vim
:igit
:igit commit
:igit log
:igit push
:igit branch
:igit stash
:igit log %
:igit log src/main.rs
:igit log "src/a file.rs"
:IgitClose
```

`:Igit` is the actual Neovim command; `:igit` is a command-line abbreviation. It expands only when typed at the start of an Ex command, followed by a space or Enter. It does not alter search text or command arguments. Use `Igit` in mappings, scripts, `vim.cmd()`, or after command modifiers such as `silent`. An existing `igit` abbreviation is left intact.

Panel names and file paths support completion. A file path is accepted only after `log`; either quote paths with spaces or escape them with `\`. `%` means the file in the originating editor buffer, including when invoking another command from the IGit terminal. The buffer must have a file name. For a literal file named `%`, use `./%`.

IGit starts in the invoking window's current working directory, including `:lcd` or `:tcd`. It receives the file history target as `igit log -- <absolute-file-path>`. Saved file history comes from Git; unsaved editor changes are not passed to IGit. Use `:lcd` to change the workspace or pass `cwd` to the Lua API.

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
})
```

When omitted, floating windows use 90% of the available width and 85% of the height. Side splits use 50% of the width; bottom splits use 40% of the height. Tabs occupy the whole tab page. Floating windows and splits resize with the editor. Only the relevant dimension applies to a split.

Identical commands in the same working directory reuse their terminal session. Opening a different panel or file hides the old window and creates or resumes another session. This preserves drafts and running operations. `:IgitClose` or `require("igit").close()` hides the window and returns focus; the process keeps running. Reopen the same command to resume it, or use Neovim's buffer list. Use IGit's normal quit action to finish a session; a successful exit removes its terminal buffer. Failed processes leave their output available, report the exit code, and allow a fresh launch on the next invocation. `:bdelete!` explicitly stops and removes a terminal session.

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

## Lua API and mappings

```lua
local igit = require("igit")

igit.open() -- Commit
igit.open("stash")
igit.open("log", { file = "%" })
igit.open("log", {
  file = "src/main.rs",
  cwd = "/path/to/workspace",
  window = { layout = "right", width = 70 },
})
igit.close()

vim.keymap.set("n", "<leader>gg", function() igit.open() end, { desc = "IGit" })
vim.keymap.set("n", "<leader>gl", function()
  igit.open("log", { file = "%" })
end, { desc = "IGit file history" })
```

`open(panel?, options?)` returns the terminal buffer number, or `nil, error` and a notification. `panel` defaults to `"commit"`; `options` supports `file`, `cwd`, and per-opening `window` overrides. Changing a layout reuses the same process. `close()` returns whether a managed window was hidden. Calling `setup()` again replaces the configuration with the defaults plus the supplied options; existing jobs continue running.

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
```

The suite uses temporary files and fake terminal processes; it does not invoke Git, real IGit, or external services. It exercises real Neovim windows, jobs, command-line input, and session cleanup. The Neovim 0.10 API baseline is documented in the official [window and command APIs](https://github.com/neovim/neovim/blob/v0.10.4/runtime/doc/api.txt) and [terminal job functions](https://github.com/neovim/neovim/blob/v0.10.4/runtime/doc/builtin.txt). The included suite has been run on Neovim 0.12.4.

See `:help igit.nvim` for the reference. Package managers usually generate help tags; for a manual installation, run `:helptags ALL` once.
