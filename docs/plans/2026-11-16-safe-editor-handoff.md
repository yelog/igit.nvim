# Safe Editor Handoff Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make native IGit's edit and revision actions open in Neovim without abandoning unsaved source buffers or replacing utility windows.

**Architecture:** Keep the authenticated OSC 51 protocol and native Git implementation unchanged. Select a suitable existing editing window before switching buffers; create a split when every candidate is protected. Continue using guarded buffer commands and retain the terminal until opening succeeds.

**Tech Stack:** Neovim 0.10+ Lua APIs, dependency-free headless integration tests, local fake terminal processes.

**Scope:** This handoff change keeps the native editor protocol unchanged.
Capability negotiation and repository invalidation are separate companion
workflow improvements. This checkout owns companion implementation, tests, and
documentation; native documentation, builds, and executable integration runs
remain with the main integration task.

---

### Task 1: Reproduce protected source windows

**Files:** Modify `tests/run.lua`.

Add cases with `hidden=true`, a modified source buffer, and each destructive
`bufhidden` value: `wipe`, `delete`, and `unload`. Check that opening a working
file preserves the source buffer, contents, options, and running terminal job.
Replace the old `nohidden` failure expectations with successful split fallback
checks for both working files and revisions.

Run `nvim --headless -u NONE -l tests/run.lua`. Expect the new regression to
fail with the existing `E37` behavior before implementation.

### Task 2: Select safe editing windows

**Files:** Modify `lua/igit/editor.lua` and `tests/run.lua`.

Prefer a suitable window already displaying the requested buffer, then the
source editing window, then another suitable window in the source tab. Skip
floating, preview, terminal, utility, and buffer-locked windows when replacing
another buffer. An ordinary window already showing the target may receive focus
even when buffer-locked. Reuse plugin revision buffers. Preserve modified buffers
that cannot be hidden safely by opening a new split.

Keep buffer switching guarded. On failure, clean up an unchanged newly created
split, preserve any unsaved target, restore terminal focus, and show a concise
diagnostic. Cover locked windows,
utility windows, target reuse, and failed opening without modifying user files
or Git state.

Run `nvim --headless -u NONE -l tests/run.lua` on Neovim 0.12.4. Run the focused
handoff regressions on Neovim 0.10.4 when a working executable is available.
A planned 0.10.4 run is not evidence of current compatibility; record only
checks that actually execute successfully.

### Task 3: Document and verify the behavior

**Files:** Modify `README.md`, `doc/igit.txt`, and this companion plan. Coordinate
the native checkout's design, architecture, and product documentation separately
with the main integration task.

Document safe window selection, split fallback, preserved unsaved content, and
unchanged terminal lifecycle. Run the terminal, lifecycle, capabilities,
editor, and file-diff integration suites. Check help tags and whitespace.
Record the executed checks without committing or publishing.

## Implemented boundaries

| Area | Delivered behavior and limits |
| --- | --- |
| Hunk review | Explicit staged/unstaged previews compare HEAD/index/buffer; navigation can filter either comparison. Switching stays at the original source line and reports when that comparison has no hunk. Existing cursor, range, and whole-file actions retain their scopes. Ignored untracked files, conflicts, binary/non-UTF-8 data, special modes, conversions, and files above the configured 1 MiB default limit remain unsupported. File-only mode changes require a separate Git action. |
| Undo Stage | At most 100 successful stage/unstage actions are retained across paths and repositories in the current Neovim process. The path's blob, registration, executable mode, and assume-unchanged/skip-worktree flags are restored only when its recorded post-state still matches. Stage/unstage also compare captured flags. The real index lock protects a private candidate built from the latest index; sibling entries remain intact. Old blob bytes are not persisted: a missing, wrong-type, or unreadable object refuses Undo and retains history. Intent-to-add entries are rejected. |
| Return synchronization | Ordinary hide, window close, and exit reconcile loaded files within session roots. Clean buffers run `checktime`; dirty buffers keep unsaved content and warn on detected disk changes. Fingerprints hash at most 1 MiB and otherwise compare metadata, so edits preserving every compared metadata value can be missed. Authenticated repository events are invalidations, not successful-write notifications. Current-file diff keeps its separate private snapshot/import lifecycle. |
| Capabilities and health | A one-second `--capabilities` probe is cached by executable identity, timestamps, and argv. Ordinary panels can start with older or invalid capability responders. Integrated actions diagnose missing features; editor, revision, and repository events require bridge protocol 1, while current-file diff requires its advertised capability. Running sessions retain their original contract. `:checkhealth igit` reports the selected executable and supported contract. |
| Safe handoff | Window selection stays within the source tab, prefers the existing target, and preserves protected source buffers and utility windows. A new split is a fallback, not a guarantee that opening can succeed under every size or autocommand. On failure the running terminal remains available; unused fallback splits are closed, while modified target text is retained. Only the active originating terminal can open targets or display protocol errors. Revision reads remain bounded to UTF-8 non-binary blobs of at most 512 KiB with a 15-second Git timeout. |

Current validation and the native-test review are recorded in
[the companion verification report](../verification/2026-11-16-plugin-headless.md).
Current complete-suite execution uses Neovim 0.12.4. Neovim 0.10.4 remains
unverified; earlier claims without execution logs are excluded from this
verification record.

## Verification record

Completed on November 16, 2026.

- Neovim 0.12.4: all nine dependency-free suites pass, totaling 208 cases.
  This includes 56 terminal/handoff, 66 hunk/index, 9 status, 13 blame,
  17 browse, 8 editor, 17 file-diff, 7 capability and 15 lifecycle cases.
- The capability suite exercises the actual health provider with compatible
  and legacy fake executables.
- Help tags, local documentation links and whitespace checks pass.
- Neovim 0.10.4 was not validated successfully. The attempted downloaded
  executable exited with status 137 even for `--version`.
- Native integration results against the freshly built executable are recorded
  in the companion verification report, separately from the fake-process suite.
