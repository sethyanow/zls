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

**R6 test (on-demand fallback):** Same fixture files. Exercise the `gatherWorkspaceReferenceCandidates` fallback path (no build system) with `file://` URIs. The on-demand loading code in the fallback path calls `getOrLoadHandle` for `file_imports` URIs not yet in the store, loading them during the reference search. Assert that findReferences discovers cross-file results via the on-demand path.

**R7 test:** Already covered by existing cross-file tests at `references.zig:304-351` using `untitled://` infrastructure. Once R5/R6 ensure files are loaded, findReferences works without changes. No new test needed.

### Implementation steps

1. **Create test fixture files** — `tests/fixtures/eager_load/{a.zig, b.zig, c.zig}` with import chain.

2. **Write R5 test** — in `tests/lsp_features/references.zig`. Open `a.zig` with `file://` URI. Assert transitive imports loaded.

3. **Write R6 test** — in `tests/lsp_features/references.zig`. Exercise the on-demand loading in the fallback path using the same fixture files. Assert findReferences discovers cross-file results.

4. **DocumentStore eager loading** — in `src/DocumentStore.zig`, after `file_imports` are computed for a handle (around the `collectImports` / `updateFileImports` area), iterate the new `file_imports` and call `getOrLoadHandle` for each URI not already in `handles`. Since `getOrLoadHandle` triggers parsing which computes `file_imports` for the newly loaded file, this naturally cascades. Guard against cycles with a visited set or by checking `handles.contains(uri)` before loading (which `getOrLoadHandle` already does — it returns the existing handle if present).

5. **On-demand fallback in gatherWorkspaceReferenceCandidates** — in the fallback path (references.zig:369-391), when building `per_file_dependants`, also attempt to load any `file_imports` URI that isn't in the store yet. This ensures files discovered during the import graph walk are loaded even if the eager path somehow missed them.

6. **Verify all tests pass** — `zig build test --summary all`, `zig build check`, `zig fmt --check .`

## Success Criteria
- [x] R5 test: opening a file loads its transitive imports into DocumentStore
- [x] R6 test: on-demand fallback loads imports not in store during reference search (purge-and-reload scenario)
- [x] R7: existing cross-file reference tests still pass (no changes to references handler)
- [x] Each test fails before its corresponding implementation (red step verified)
- [x] DocumentStore eagerly loads transitive imports on file open
- [x] gatherWorkspaceReferenceCandidates loads unresolved imports on-demand
- [x] `zig build test --summary all` passes (all existing tests still green)
- [x] `zig build check` compiles clean
- [x] `zig fmt --check .` passes
- [x] `ensureHandleLoaded` API added to DocumentStore (deadlock fix for recursive loading)
- [x] Adversarial tests added: self-referential import, circular chain, missing file

## Anti-Patterns
- NO modifying the references handler (R7: fix is in DocumentStore and gatherWorkspaceReferenceCandidates only)
- NO artificial loading limits (R5: unbounded transitive loading)
- NO writing implementation before the test fails (TDD: red-green-refactor)
- NO mashing multiple requirements into one test (each R gets its own)
- NO runtime file creation of any kind in tests (all test data is checked-in fixtures — no exceptions, no "but the scenario requires it")

## Key Considerations

- **`untitled://` vs `file://`:** R5/R6 tests MUST use `file://` URIs because `getOrLoadHandle` for non-file schemes does a lookup only, not a disk load. R7 is already covered by existing `untitled://` tests.
- **HandleIterator stability:** `handles` is `ArrayHashMap` (appends on insert). Index-based iteration is safe when new handles are added during iteration — new entries go to the end.
- **getOrLoadHandle returns null:** File not on disk. Skip gracefully, continue to next import.
- **Error propagation:** `getOrLoadHandle` returns `error.Canceled` or `error.OutOfMemory`. Propagate these (resource exhaustion / shutdown). All other errors return null.
- **Cycle safety:** `getOrLoadHandle` returns existing handle if present, so re-visiting a URI is a no-op.
- **Recursive call stack (adversarial):** Eager loading is recursive: `getOrLoadHandle` → `createAndStoreDocument` → parse → `updateFileAndTree` → eager loading fires again. Stack depth = import chain depth (not total file count). ~20-50 levels max for real Zig projects. Accept per R5; convert to iterative worklist only if stack overflow reported.
- **didOpen latency (adversarial):** Eager loading adds blocking I/O to file open. 100 imports × slow disk = noticeable lag. Inherent to the design — on-demand-only shifts latency to first analysis instead. Accept per R5.
- **Double execution is safe (adversarial):** `didOpen` then `didChange` both trigger eager loading. Second pass calls `getOrLoadHandle` on already-loaded URIs which returns existing handles. No-op by design.

## Key Files
- `src/DocumentStore.zig` — primary change: eager loading after file_imports computed
- `src/features/references.zig:327-391` — gatherWorkspaceReferenceCandidates on-demand fallback
- `tests/fixtures/eager_load/` — new fixture files (a.zig, b.zig, c.zig)
- `tests/lsp_features/references.zig` — R5 and R6 tests

## Log

- [2026-04-12T12:43:02Z] [Seth] SRE refinement: Split monolithic test into three per-requirement tests. R5 (eager loading) and R6 (on-demand) use file:// fixtures checked into repo. R6 scenario: late-arriving file simulating Bazel-generated comptime bindings. R7 already covered by existing untitled:// cross-file tests. No changes to implementation steps 2-3.
- [2026-04-12T17:28:02Z] [Seth] Fixed skeleton inconsistency: R6 test description said 'create c.zig on disk' which contradicted anti-pattern 'no runtime file creation'. Next session exploited this as a loophole. R6 test now uses same checked-in fixture files as R5 — isolation comes from exercising different code paths, not different file states.
- [2026-04-13T12:40:04Z] [Seth] Implementation complete. Key changes: (1) Added ensureHandleLoaded API on DocumentStore — non-blocking contains check then getOrLoadHandle if absent. (2) R5 eager loading uses ensureHandleLoaded + early event.set (Option 1 + Option 3 defense in depth). (3) R6 fallback uses ensureHandleLoaded. (4) Adversarial tests: self-referential import, circular chain, missing file. (5) Test fixtures checked into tests/fixtures/eager_load/. Critical lesson: original adversarial planning marked circular imports as 'safe (Zig disallows)' — wrong because parser accepts them. The deadlock lived in that gap. Saved lesson to feedback memory.
