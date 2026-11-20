# Ignored File Hunks Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Keep Git-ignored working files out of hunk signs and change counts without hiding changes to tracked files.

**Architecture:** Keep ignore detection inside the asynchronous hunk snapshot reader, independent of the status cache. Ask Git about ignore rules only when the path is absent from both the index and HEAD. Publish a successful ignored snapshot with empty hunks and current zero counts, and reject write/reset actions for that snapshot.

**Tech Stack:** Neovim Lua, `vim.system`, Git `check-ignore`, extmarks, dependency-free headless integration tests.

---

### Task 1: Reproduce ignored-file decorations

**Files:**
- Modify: `tests/hunks.lua`
- Modify: `tests/status.lua`

Add temporary-repository regressions for:

- A previously untracked file becoming ignored: existing signs disappear.
- Root and nested `.gitignore`, ignored directories, `.git/info/exclude`, and a repository-local `core.excludesFile`.
- Negated rules and ordinary untracked files retaining their additions.
- Unsaved ignored contents retaining zero staged and unstaged counts.
- Ignored files in an unborn repository.

Run `nvim --headless -u NONE -l tests/hunks.lua` and
`nvim --headless -u NONE -l tests/status.lua`.
Expect the new assertions to expose additions and counts for ignored content.

### Task 2: Classify ignored snapshots

**Files:**
- Modify: `lua/igit/hunks.lua`
- Modify: `tests/hunks.lua`

Finish index/HEAD reads through a shared local completion function. If either
version has an entry, preserve normal tracked-file behavior. Otherwise run:

```lua
git.run(context.repo, { "--no-literal-pathspecs", "check-ignore", "--quiet", "--", context.path }, {}, function(result)
  if result.code ~= 0 and result.code ~= 1 then
    return callback(git.error(result))
  end
  snapshot.ignored = result.code == 0
  callback(nil, snapshot)
end)
```

Disable the adapter's literal-pathspec flag for this command: `check-ignore`
accepts literal filenames directly and rejects pathspec magic.

For ignored snapshots, calculate neither unstaged nor staged differences;
publish empty summaries with the current changedtick. Keep the context/watch
attached so subsequent editor refreshes recheck ignore rules. Reject all hunk
and whole-file stage, unstage, and reset actions before changing any data.

Cover tracked paths matching ignore patterns, force-added files, staged
deletions, rule removal, Git errors, and buffer/index/disk preservation.

### Task 3: Document and verify

**Files:**
- Modify: `README.md`
- Modify: `doc/igit.txt`

Document ignored-file signs, counts, and action behavior alongside hunk help.
Run the hunk, status, and editor integration suites, followed by the remaining
dependency-free suites. Validate help tags in a temporary directory and run
`git diff --check`. Do not commit, push, or modify the native IGit repository.

## Validation record

Completed on 2026-11-16:

- Neovim 0.12.4: 39 hunk, nine status, seven editor, 13 blame, 17 browser,
  17 file-diff, and 43 terminal integration cases passed (145 total).
- Neovim 0.10.2: all 39 hunk and nine status cases passed.
- Help tags generated successfully in a temporary directory.
- `git diff --check` passed.

The new regressions failed before the fix: ignore-rule changes retained signs,
and ignored buffers published added lines. The fix also preserves ordinary
untracked files, tracked/force-added files, staged deletions, and buffer/index/
disk contents when an ignored-file action is rejected.
