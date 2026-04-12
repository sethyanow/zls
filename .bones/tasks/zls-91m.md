---
id: zls-91m
title: Implement eager transitive import loading in DocumentStore
status: closed
type: task
priority: 1
owner: Seth
parent: zls-h4v
---







## Context
First task in Phase 1 (zls-h4v) of the call hierarchy epic (zls-xjj).

The `DocumentStore` computes `file_imports` for each opened file (list of URIs from `@import` expressions). Currently, these imports are only resolved to handles on-demand. The fallback path in `gatherWorkspaceReferenceCandidates` (references.zig:369-391) iterates only handles already in the store, missing files that haven't been opened.

This task adds eager transitive loading: when a file's `file_imports` are computed, any imported file not already in the store is loaded, and its imports are followed transitively.

Additionally, `gatherWorkspaceReferenceCandidates` gets an on-demand fallback to load files it encounters during the search that aren't loaded yet.

## Requirements
- R5: Eager transitive import loading on file open, unbounded
- R6: On-demand loading fallback in gatherWorkspaceReferenceCandidates
- R7: findReferences benefits automatically (no changes to references handler)

## Implementation

### Tests — three separate tests, one per requirement

**R5 test (eager loading):** Check into repo: `tests/fixtures/eager_load/{a.zig, b.zig, c.zig}` with import chain a→b→c. Open `a.zig` via `textDocument/didOpen` with `file://` URI. Assert `b.zig` and `c.zig` are in the DocumentStore. This tests DocumentStore behavior, not references.

**R6 test (on-demand fallback):** Same fixture structure but with a late-arriving file. Open `a.zig` when `b.zig` exists but `c.zig` does NOT exist on disk. R5 eager-loads `b.zig`, but `b.zig`'s import of `c.zig` fails (not found). Then create `c.zig` on disk (simulating build output, e.g. Bazel generating comptime bindings). Run findReferences — R6 discovers `c.zig` on-demand during the search. Assert `c.zig` is now in the store.

**R7 test:** Already covered by existing cross-file tests at `references.zig:304-351` using `untitled://` infrastructure. Once R5/R6 ensure files are loaded, findReferences works without changes. No new test needed.

### Implementation steps

1. **Create test fixture files** — `tests/fixtures/eager_load/{a.zig, b.zig, c.zig}` with import chain. R6 uses a SEPARATE directory `tests/fixtures/eager_load_late/{a.zig, b.zig}` (c.zig created at runtime by the test, cleaned up via defer).

2. **Write R5 test** — in `tests/lsp_features/references.zig`. Open `a.zig` with `file://` URI. Assert transitive imports loaded.

3. **Write R6 test** — in `tests/lsp_features/references.zig`. Open `a.zig` when `c.zig` missing, create `c.zig`, run findReferences, assert on-demand load.

4. **DocumentStore eager loading** — **CRITICAL: Do NOT hook inside `createAndStoreDocument` or `Handle.refresh`** (future event not yet set → deadlock on cycles). Hook AFTER `createAndStoreDocument` returns, in `openLspSyncedDocument` (after line 862) and after `getOrLoadHandle` returns in the non-LSP path. Iterate the returned handle's `file_imports`, call `getOrLoadHandle` for each URI not already in `handles` (check `store.handles.contains(uri)` or `store.getHandle(uri) != null` first — do NOT call `getOrLoadHandle` to check, it awaits). Each newly loaded handle's `file_imports` feeds the next iteration (worklist pattern). Guard against cycles with `handles.contains(uri)` check before loading.

5. **On-demand fallback in gatherWorkspaceReferenceCandidates** — in the fallback path (references.zig:369-391), when building `per_file_dependants`, also attempt to load any `file_imports` URI that isn't in the store yet. This ensures files discovered during the import graph walk are loaded even if the eager path somehow missed them.

6. **Verify all tests pass** — `zig build test --summary all`, `zig build check`, `zig fmt --check .`

## Success Criteria
- [x] R5 test: opening a file loads its transitive imports into DocumentStore
- [x] R6 test: on-demand fallback loads late-arriving files during reference search
- [x] R7: existing cross-file reference tests still pass (no changes to references handler)
- [x] Each test fails before its corresponding implementation (red step verified)
- [x] DocumentStore eagerly loads transitive imports on file open
- [x] gatherWorkspaceReferenceCandidates loads unresolved imports on-demand
- [x] `zig build test --summary all` passes (all existing tests still green)
- [x] `zig build check` compiles clean
- [x] Eager loading does not deadlock on self-imports or cycles (structural: hook runs after event is set)
- [x] `zig fmt --check .` passes

## Anti-Patterns
- NO modifying the references handler (R7: fix is in DocumentStore and gatherWorkspaceReferenceCandidates only)
- NO artificial loading limits (R5: unbounded transitive loading)
- NO writing implementation before the test fails (TDD: red-green-refactor)
- NO mashing multiple requirements into one test (each R gets its own)
- NO runtime temp file creation for test fixtures (check fixture files into the repo)

## Key Considerations

- **`untitled://` vs `file://`:** R5/R6 tests MUST use `file://` URIs because `getOrLoadHandle` for non-file schemes does a lookup only, not a disk load. R7 is already covered by existing `untitled://` tests.
- **HandleIterator stability:** `handles` is `ArrayHashMap` (appends on insert). Index-based iteration is safe when new handles are added during iteration — new entries go to the end.
- **getOrLoadHandle returns null:** File not on disk. Skip gracefully, continue to next import.
- **Error propagation:** `getOrLoadHandle` returns `error.Canceled` or `error.OutOfMemory`. Propagate these (resource exhaustion / shutdown). All other errors return null.
- **Cycle safety:** `getOrLoadHandle` returns existing handle if present, so re-visiting a URI is a no-op.

### Failure Catalog (Adversarial Planning)

**Temporal Betrayal: Deadlock in eager loading within `createAndStoreDocument`**
- Assumption: We can call `getOrLoadHandle` for import URIs immediately after `Handle.refresh` computes `file_imports`.
- Betrayal: `createAndStoreDocument` holds the handle's future event (`handle_future.event.set` is deferred at line 1649). If an imported file imports BACK to the original (circular `@import` in source text, or A→B→A), `getOrLoadHandle` finds the handle in `handles`, awaits its future which isn't set yet → **deadlock** (single-threaded test context blocks forever).
- Consequence: Hang on any circular or self-referencing import in source text.
- Mitigation: **Do NOT call `getOrLoadHandle` inside `createAndStoreDocument`.** Hook eager loading AFTER `createAndStoreDocument` returns (after event is set). Call site is in `openLspSyncedDocument` (line 851) or after the `getOrLoadHandle` call in references.zig build-system path. Alternatively, use `handles.contains(uri)` to skip already-present URIs — but this only prevents self-loops, not A→B→A where B is a new file whose loading triggers a nested `getOrLoadHandle(A)`.

**CORRECTION — Skeleton's "Cycle safety" claim is WRONG:**
- The skeleton says "getOrLoadHandle returns existing handle if present, so re-visiting a URI is a no-op." This is false. `getOrLoadHandle` → `createAndStoreDocument` → `getOrPut` finds existing → **awaits** the future (line 1610). If the future isn't set yet (same thread is still loading it), this deadlocks. The safe cycle check is `store.handles.contains(uri)` or `store.getHandle(uri) != null`, NOT `getOrLoadHandle`.

**State Corruption: R6 test fixture cleanup**
- Assumption: Runtime-created c.zig (the late-arriving file) is cleaned up after the R6 test.
- Betrayal: If R6 test crashes before cleanup, c.zig persists in the fixtures directory. If R5 and R6 share the same fixture directory, subsequent R5 runs find c.zig already present → R5 passes for the wrong reason.
- Consequence: Non-deterministic R5 test results after a failed R6 run.
- Mitigation: **Use separate fixture directories** for R5 and R6. R5: `tests/fixtures/eager_load/`. R6: `tests/fixtures/eager_load_late/` (contains a.zig, b.zig pre-checked-in; c.zig is created and `defer`-deleted at runtime). Alternatively, R6 creates c.zig in a temp directory but that conflicts with needing it relative to b.zig's import path — so separate fixture dirs is the clean approach.

**Temporal Betrayal: `per_file_dependants` stale after on-demand load**
- Assumption: The reverse dependency map in `gatherWorkspaceReferenceCandidates` fallback (line 369-377) captures all import relationships.
- Betrayal: On-demand loading adds new files to the store, but `per_file_dependants` was built from the snapshot of handles at iteration start. Newly loaded files' import relationships are invisible.
- Consequence: On-demand loaded files are in the store but their dependants/dependencies aren't in the search's reverse map — partial coverage.
- Mitigation: **Use forward-walking pattern instead of reverse map.** The build-system path (lines 358-365) follows `handle.file_imports` transitively — this naturally picks up newly loaded files. Restructure the fallback to walk forward from target_handle's file_imports (and their file_imports, etc.), loading via `getOrLoadHandle` as it goes. This mirrors the build-system path and avoids the stale reverse map entirely.

**Temporal Betrayal: Test needing `file://` URIs via `addDocument`**
- Assumption: Test context's `addDocument` can open files with `file://` URIs.
- Betrayal: `addDocument` (context.zig:93) hardcodes `untitled://` scheme. Cannot produce `file://` URIs.
- Consequence: R5/R6 tests must send raw `textDocument/didOpen` notifications with `file://` URIs directly via `self.server.sendNotificationSync`, bypassing `addDocument`. The text content must still be provided (LSP didOpen includes the text), but the URI must be `file://` pointing to the real fixture path so that `@import` resolution produces correct `file://` URIs for the imported files.
- Mitigation: Construct `file://` URIs from absolute paths of fixture files. Send `textDocument/didOpen` directly. The imported files will be loaded from disk via `getOrLoadHandle(.uri)` — they don't need `didOpen`, the eager loader handles them.

## Key Files
- `src/DocumentStore.zig` — primary change: eager loading after file_imports computed
- `src/features/references.zig:327-391` — gatherWorkspaceReferenceCandidates on-demand fallback
- `tests/fixtures/eager_load/` — new fixture files (a.zig, b.zig, c.zig)
- `tests/lsp_features/references.zig` — R5 and R6 tests

## Log

- [2026-04-12T12:43:02Z] [Seth] SRE refinement: Split monolithic test into three per-requirement tests. R5 (eager loading) and R6 (on-demand) use file:// fixtures checked into repo. R6 scenario: late-arriving file simulating Bazel-generated comptime bindings. R7 already covered by existing untitled:// cross-file tests. No changes to implementation steps 2-3.
- [2026-04-12T16:53:42Z] [Seth] Adversarial planning complete. Critical findings: (1) DEADLOCK risk — eager loading must NOT run inside createAndStoreDocument (future event not set yet, getOrLoadHandle awaits → hangs on cycles). Hook point moved to after createAndStoreDocument returns. (2) Skeleton cycle-safety claim corrected — getOrLoadHandle awaits, doesn't return immediately. Safe check is handles.contains(uri). (3) R6 test needs separate fixture dir from R5 to prevent cross-contamination on cleanup failure. (4) addDocument uses untitled:// — tests must send raw didOpen with file:// URIs. (5) On-demand fallback should use forward-walking pattern (like build-system path) instead of stale reverse dependency map.
- [2026-04-12T17:12:16Z] [Seth] Task complete. Implementation: loadTransitiveImports in DocumentStore (worklist pattern, getHandle guard for cycles), called from openLspSyncedDocument and references.zig workspace search. Key design change from skeleton: on-demand loading placed BEFORE gatherWorkspaceReferenceCandidates (not in fallback path) because .unresolved build file returns .empty, making fallback unreachable. 6 tests: R5 (eager), R6 (on-demand), self-import, diamond, empty, idempotency. Full suite 579/590 pass (11 skipped). Adversarial stress test clean.
