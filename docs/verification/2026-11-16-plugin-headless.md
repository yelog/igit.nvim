# Companion verification: November 16, 2026

The complete dependency-free companion suite passes: **208 cases across nine
scripts**, with every Neovim process returning exit code 0. The count includes
56 terminal/handoff cases and 66 hunk/index cases. Health checks are included in
the capability suite; help-tag checks are additional validation.

## Environment and execution

- Checkout: `/Users/yelog/workspace/vi/igit.nvim`.
- Neovim: 0.12.4, release build.
- Git: 2.54.0 (Apple Git-157).
- Tests use disposable local repositories and fake terminal processes.
- The dependency-free suite run executed no Cargo commands or native smoke
  cases. The main integration pass subsequently rebuilt both native commands
  and ran the real-process checks below.
- Current complete-suite validation on Neovim 0.10.4 remains unverified.

Earlier notes claimed focused Neovim 0.10.4 and old-binary smoke results
without available execution logs. Those claims are excluded from the current
verification record. The attempted downloaded 0.10.4 executable exited with
status 137 even for `--version`. Lifecycle and file-diff integration against
the freshly built native executable are recorded separately.

Executed from the checkout root:

```sh
for suite in run hunks status blame browse editor file_diff capabilities lifecycle; do
  nvim --headless -u NONE -l "tests/$suite.lua"
done
```

| Script | Cases | Exit code |
| --- | ---: | ---: |
| `tests/run.lua` | 56 | 0 |
| `tests/hunks.lua` | 66 | 0 |
| `tests/status.lua` | 9 | 0 |
| `tests/blame.lua` | 13 | 0 |
| `tests/browse.lua` | 17 | 0 |
| `tests/editor.lua` | 8 | 0 |
| `tests/file_diff.lua` | 17 | 0 |
| `tests/capabilities.lua` | 7 | 0 |
| `tests/lifecycle.lua` | 15 | 0 |
| **Total** | **208** | **All 0** |

Raw per-script output, exit-code summary, and help-tag output are saved in:

```text
/var/folders/d9/5sfcnz292bvbdh3nv19rvhc40000gn/T/igit-plugin-headless-final.zTzX6V/
```

Blame reports `PASS all 13 blame integration cases`; browse reports
`ALL PASS (17)`. These are successful summaries even though they do not use the
other scripts' `Passed N ...` format.

## Health, help, and static checks

The capability suite invokes the real `:checkhealth igit` provider with
compatible and legacy fake executables. It verifies the resolved executable,
version, protocol, all four features, and the warning that ordinary panels can
still start with an unsupported capability responder.

A separate real `:checkhealth igit` run configured the freshly built absolute
native executable. It passed assertions for the resolved path, version 0.1.3,
all four supported features and absence of health errors.

`helptags doc` succeeds. All 16 checked plugin tags and internal help references
open this checkout's `doc/igit.txt`, including:

- `igit.nvim`
- `igit-hunks`
- `:IgitUndoStage`
- `igit-edit-file`
- `igit-revision-file`
- `igit-sessions`
- `igit-health`

Both `tests/native_lifecycle.lua` and `tests/native_file_diff.lua` pass
`loadfile` syntax checks and the later actual-native execution below.
Local Markdown links in README, the handoff plan, and this report resolve.
`git diff --check` passes.

## Native integration

The main integration task built both native commands with
`python3 scripts/cargo_serial.py build --locked --bins`. Both `igit` and `ig`
return the same schema-1/editor-protocol-1 capability contract, including
`editor`, `revision`, `file-diff` and `repository-events`.

These commands were executed from the companion checkout with Neovim 0.12.4;
both exit successfully:

```sh
IGIT_NATIVE_BINARY=/Users/yelog/workspace/tui/igit/target-serial/debug/igit \
  nvim --headless -u NONE -l tests/native_lifecycle.lua
IGIT_NATIVE_BINARY=/Users/yelog/workspace/tui/igit/target-serial/debug/igit \
  nvim --headless -u NONE -l tests/native_file_diff.lua
```

The fixture confines Git writes and branch checkouts to a newly created
temporary repository, uses isolated native state/configuration directories, and
disables update checks. It queries the actual binary's capability contract,
waits for a visible startup marker, checks out a second branch, sends F5, and
expects repository invalidation to reconcile a clean buffer while preserving
terminal focus and dirty-buffer contents, changedtick, and modified state.
It changes branches separately before hiding and before hidden exit, verifying
clean-buffer reload at both boundaries. Hiding retains the running process and
restores the source buffer. All three reconciliation boundaries preserve the
dirty buffer's text, changedtick and modified state. Final Git diffs assert
that lifecycle handling did not write buffer edits or change staged content.

The native case exercises positive authenticated event acceptance. Foreign,
malformed, hidden-session, and delayed-event behavior is covered separately by
the dependency-free capability/lifecycle suites.

The actual file-diff case also passes: unsaved source content and cursor
centering, individual hunk restoration, lowercase/uppercase in-viewer undo,
one-step editor undo, navigation/reopening/hiding, final-newline metadata
undo/redo, BOM restoration, new unsaved files and empty buffers. HEAD, exact
real-index bytes, staged sibling content and working-file bytes remain intact.

## Documentation review

README, help, and the safe-editor-handoff plan now distinguish these boundaries:

1. Explicit hunk comparisons and filtered navigation retain existing range
   staging. A comparison without a hunk at the source line reports that result
   and keeps the current preview.
2. Undo Stage retains at most 100 process-local actions, checks the path's
   post-state including flags, preserves sibling entries, and refuses missing,
   wrong-type, or unreadable old blobs while retaining its history record.
3. Ordinary return synchronization covers loaded files within session roots.
   Dirty buffers are preserved. Fingerprints hash at most 1 MiB and use
   metadata for larger files, with the corresponding metadata-preserving-edit
   limitation. Repository events are authenticated invalidations.
4. Capability probes have a one-second timeout and executable-identity cache.
   Older binaries retain ordinary panel startup. Integrated features require
   the corresponding advertised capability and applicable bridge protocol.
5. Safe handoff uses source-tab windows and split fallback. Existing target
   windows may be focused while buffer-locked; inactive requests cannot open
   editor buffers or show delayed diagnostics. Opening can still fail, and
   modified target text is retained after a failed fallback.

The help's development executable path uses `target-serial/debug/igit`; its
argv example uses an already-built command instead of initiating a build.
Neovim 0.10.4 compatibility is not established by this verification pass.

No production Lua changes were needed during the final dependency-free
verification pass. Existing user changes were preserved. Git-writing checks
used disposable repositories; no commit, push, reset or branch operation was
performed in the product checkouts.
