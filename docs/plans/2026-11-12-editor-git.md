# Editor Git Features Implementation Plan

**Goal:** Add configurable hunk signs and actions, file and inline blame, and browser links without requiring the IGit executable for editor features.

**Architecture:** Keep the existing terminal and revision bridge intact. Share an argv-based asynchronous Git adapter between independent hunk, blame, and browsing modules. Compare buffer, index, and HEAD separately; apply one reviewed hunk to the index and make resets undoable buffer edits.

**Tech Stack:** Neovim 0.10 Lua APIs, `vim.system`, `vim.diff`, extmarks, system Git, dependency-free headless integration tests.

## 1. Shared Git adapter and hunk model

Create `lua/igit/git.lua`, `lua/igit/hunks.lua`, and `tests/hunks.lua`.
Resolve repositories from file locations, including nested repositories and
worktrees. Read index stage entries and HEAD blobs asynchronously. Diff the
index against the live buffer for unstaged changes, and HEAD against the index
for staged changes. Map staged positions through unstaged edits.

Use configurable extmark signs with independent highlights. Debounce refreshes,
discard obsolete reads, and refresh after editor or external Git changes.
Navigate both staged and unstaged hunks without installing global mappings.

Stage and unstage one hunk with an index-only Git patch. Include complete file
context to reject a conflicting index; retain unrelated files and other hunks.
Reset only the current unstaged buffer hunk, preserving the index, disk, and
Neovim undo. Reject unmerged, binary, and unsupported file types.

Run `nvim --headless -u NONE -l tests/hunks.lua`. Inspect real index blobs, disk
bytes, buffer text, and unrelated staged files. Cover additions, deletions,
unsaved edits, staged-plus-unstaged files, offsets, Unicode paths, no final
newline, new files, and stale asynchronous requests.

## 2. Blame annotations

Create `lua/igit/blame.lua` and `tests/blame.lua`.
Use `git blame --line-porcelain --contents -` against the live buffer.
Cache per-buffer results; refresh on edits and Git changes, without one blame
process per cursor move. Show uncommitted lines as `Uncommitted changes`.

Provide a synchronized annotation split with date, author, and configurable age
colors. Provide configurable EOL virtual text or a statusline component. Preserve
the user's statusline and source window options when annotations close.

Run `nvim --headless -u NONE -l tests/blame.lua` with deterministic temporary
commits; verify dates, colors, unsaved changes, placements, cache, and cleanup.

## 3. Git hosting links

Create `lua/igit/browse.lua` and `tests/browse.lua`.
Resolve upstream remote and branch before falling back to origin or a sole
remote. Normalize HTTP(S) and SSH remotes without credentials; support GitHub,
GitLab, Bitbucket Cloud, and explicitly configured hosts. Encode paths, refs,
and line ranges; handle detached HEAD and reject unsupported remote schemes.

Run `nvim --headless -u NONE -l tests/browse.lua` with local repositories and
captured browser opens. Verify URLs without accessing hosting services.

## 4. Integration and reference

Update `lua/igit/init.lua`, `lua/igit/command.lua`, `plugin/igit.lua`,
`README.md`, and `doc/igit.txt`. Preserve existing terminal commands and APIs;
add editor commands, Lua actions, configuration examples, and opt-in mappings.
Initialize editor features for ordinary buffers even when setup is omitted.

Run each new suite, then `nvim --headless -u NONE -l tests/run.lua`.
Check help tags, configuration validation, command completion, and working tree
scope. Do not commit, push, publish, or modify the native IGit repository.

## Validation record

The editor implementation includes 16 hunk cases, 13 blame cases, 17 browser
cases, and five command/API integration cases. The suites inspect real temporary
Git repositories and Neovim buffers and windows, with browser opens captured
locally. They cover both Neovim 0.10.4 and 0.12.4.

The original 43-case terminal suite passes on Neovim 0.12.4. Its extreme
20-column, 8-row floating-window case fails on Neovim 0.10.4 in both the
unmodified HEAD checkout and the implementation; that existing behavior is
outside this change. Help tags and whitespace checks are also verified.
