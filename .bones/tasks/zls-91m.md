---
id: zls-91m
title: Implement eager transitive import loading in DocumentStore
status: open
type: task
priority: 1
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

1. **Write test first** — add a test case to `tests/lsp_features/references.zig` that opens two documents where file A imports file B, defines a function in B, calls it from A, and asserts `findReferences` on B's function finds the reference in A. This test should fail against current code if the import relationship isn't resolved (need to verify whether `untitled://` URI imports work in test context — if not, adapt test approach).

2. **DocumentStore eager loading** — in `src/DocumentStore.zig`, after `file_imports` are computed for a handle (around the `collectImports` / `updateFileImports` area), iterate the new `file_imports` and call `getOrLoadHandle` for each URI not already in `handles`. Since `getOrLoadHandle` triggers parsing which computes `file_imports` for the newly loaded file, this naturally cascades. Guard against cycles with a visited set or by checking `handles.contains(uri)` before loading (which `getOrLoadHandle` already does — it returns the existing handle if present).

3. **On-demand fallback in gatherWorkspaceReferenceCandidates** — in the fallback path (references.zig:369-391), when building `per_file_dependants`, also attempt to load any `file_imports` URI that isn't in the store yet. This ensures files discovered during the import graph walk are loaded even if the eager path somehow missed them.

4. **Verify existing tests still pass** — `zig build test --summary all`

5. **Verify the new test passes** — the cross-file reference test from step 1 should now pass.

## Success Criteria
- [ ] Test exists that verifies cross-file findReferences via import chain
- [ ] Test fails before implementation (red step verified)
- [ ] DocumentStore eagerly loads transitive imports on file open
- [ ] gatherWorkspaceReferenceCandidates loads unresolved imports on-demand
- [ ] New test passes after implementation
- [ ] `zig build test --summary all` passes (all existing tests still green)
- [ ] `zig build check` compiles clean
- [ ] `zig fmt --check .` passes

## Anti-Patterns
- NO modifying the references handler (R7: fix is in DocumentStore and gatherWorkspaceReferenceCandidates only)
- NO artificial loading limits (R5: unbounded transitive loading)
- NO writing implementation before the test fails (TDD: red-green-refactor)
- NO assuming `untitled://` imports work without verifying (check test infrastructure first, adapt if needed)

## Key Files
- `src/DocumentStore.zig` — primary change: eager loading after file_imports computed
- `src/features/references.zig:327-391` — gatherWorkspaceReferenceCandidates on-demand fallback
- `tests/lsp_features/references.zig` — new cross-file test case
