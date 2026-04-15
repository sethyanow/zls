---
id: zls-mxw
title: 'Phase 2 Task 4: Module-import coverage in reverse reference search'
status: open
type: task
priority: 1
parent: zls-gyi
---

## Context

Phase 2 acceptance demo (`zls-pun`) exposed a real R2/R3 gap: `incomingCalls` on a function defined in a module-imported file returns empty when the caller imports by module name (`@import("algorithms")`) rather than file path (`@import("algorithms.zig")`).

**Mechanical cause:**
- `src/DocumentStore.zig:519` — `collectImports` filters out non-`.zig` imports, so `handle.file_imports` excludes module imports by design (field doc at line 166: "Does not include imported modules").
- `src/features/references.zig:370` (build-system path) and `:389` (fallback path) — both iterate only `handle.file_imports`. Module-resolved edges are invisible to the candidate-discovery walk.
- Resolution mechanism already exists: `DocumentStore.uriFromImportStr` (line 2026) handles `.zig` paths, `std`, `builtin`, `root`, build.zig dependencies, and full `build_config.modules.import_table` lookups. Nothing in that file is being invented.

**Foreign-codebase reproducer:** `/Volumes/code/forge_worktrees/optimize/zig/forge_graph_zig/src/edge_metrics.zig:138` calls `algorithms.findBridges`; `goToDefinition` from the call site resolves correctly, but `incomingCalls` / `findReferences` from the definition at `algorithms.zig:164` returns empty.

## Design (pinned — do not redesign during SRE)

**Shape B: cache resolved module URIs on `Handle` lazily.**

A new per-handle set holds URIs resolved through `uriFromImportStr`. Populated opportunistically whenever analysis resolves an import. Read by both reverse-search paths alongside `file_imports`.

Rationale:
- Respects the existing contract on `file_imports` (file-path imports only, populated at parse time).
- Single source of resolution truth: `uriFromImportStr` is the only function that knows how module names become URIs. Caching its results rather than duplicating the resolution logic keeps the codebase coherent (Codex review reinforced this: "use `uriFromImportStr` as the single source, don't duplicate").
- Composes with the existing fallback philosophy (R6: "do something sensible when async resolution is out of sync"). First reference call may be incomplete if the build config hasn't resolved yet, but subsequent calls — after any analysis has exercised `uriFromImportStr` — see the cached edges.
- Test story only needs to trigger resolution once per fixture, not maintain a permanently-resolved build config.

## Requirements

- R-M1: Add a lazily-populated set of resolved import URIs accessible per-`Handle`. Must be thread-safe (concurrent `uriFromImportStr` callers).
- R-M2: Every successful `uriFromImportStr` call must record its result in the calling handle's resolved-imports set. Applies to the entire resolution surface — `.zig` paths, `std`, `builtin`, `root`, build dependencies, named modules.
- R-M3: Both paths of `gatherWorkspaceReferenceCandidates` (build-system and fallback) must include resolved-import edges alongside `file_imports` when walking handles.
- R-M4: Invalidation — when a handle's tree is replaced (re-parse), its resolved-imports set must be cleared. Matches the lifecycle of `file_imports`.
- R-M5: New test fixture and test exercising module-name imports end-to-end. Existing `tests/fixtures/eager_load/` covers file-path imports only.

## Implementation Steps

1. **Test helper** — add a helper in `tests/context.zig` (or a new `tests/helper_build.zig`) that constructs a `std.json.Parsed(BuildConfig)` from a JSON string and attaches it to a fake `BuildFile`, then stamps handles' `associated_build_file` to `.resolved`. Pattern already exists for `.unresolved` at `tests/lsp_features/references.zig:1124`; extend it to also populate `impl.config`. ~30-50 LOC.

2. **New fixture** — `tests/fixtures/module_imports/` with a `build.zig` defining two modules (e.g., `mod_a` with root `a.zig`, `mod_b` with root `b.zig`) where `a.zig` does `@import("mod_b")` and calls into `b.zig`. The build.zig is real (won't be executed, but its shape drives the JSON we construct in the helper).

3. **Failing test first (TDD)** — in `tests/lsp_features/references.zig`: load the module_imports fixture via the helper with a populated resolved BuildConfig. From the symbol in `b.zig`, call `findReferences`. Expect the reference in `a.zig`. Test fails before implementation (empty result).

4. **Implementation** —
   - Add `resolved_imports` field to `DocumentStore.Handle` (exact type: SRE picks from `Uri.ArrayHashMapUnmanaged(void)` guarded by `impl.mutex`, or equivalent — constraint is thread-safe mutation by `uriFromImportStr` callers).
   - In `DocumentStore.uriFromImportStr` (line 2026), after a successful resolution, insert the resolved URI into `handle.resolved_imports`. Do this for all return paths that produce a URI (`.one`, `.many`).
   - In `src/features/references.zig` `gatherWorkspaceReferenceCandidates`, both loops (build-system at :370 and fallback at :389) union `handle.resolved_imports` into the iteration source.
   - In `DocumentStore.updateFileAndTree` (~ line 452 where `file_imports` is swapped), clear `resolved_imports` alongside the file_imports update.

5. **Additional tests** —
   - Invalidation: mutate handle content, verify `resolved_imports` cleared on re-parse, new resolution re-populates.
   - Unresolved build config: resolved-imports stays empty; fallback via `file_imports` still works for any file-path imports in the fixture (regression guard).
   - Cross-module call hierarchy: `incomingCalls` on a function in `b.zig` finds the call site in `a.zig`.

6. **Forge demo re-run** — after implementation, re-run `incomingCalls` on `algorithms.findBridges` at `forge_worktrees/optimize/zig/forge_graph_zig/src/algorithms.zig:164`. Expected: the call site in `edge_metrics.zig:138` appears.

7. **Verify all tests pass** — `zig build test --summary all`, `zig build check`, `zig fmt --check .`.

## Success Criteria

- [ ] New test fixture `tests/fixtures/module_imports/` checked in with build.zig + multi-module structure
- [ ] Test helper for constructing a fake resolved BuildConfig added and reusable
- [ ] TDD: failing test precedes implementation for each requirement (R-M1 through R-M5)
- [ ] `resolved_imports` field added to `DocumentStore.Handle`, thread-safe
- [ ] `uriFromImportStr` populates `resolved_imports` on successful resolution across all paths
- [ ] `gatherWorkspaceReferenceCandidates` both paths union `resolved_imports` into candidate set
- [ ] Invalidation on re-parse — resolved_imports cleared in `updateFileAndTree`
- [ ] Cross-module findReferences test passes
- [ ] Invalidation test passes
- [ ] Unresolved-build regression test passes
- [ ] Forge-codebase demo: `incomingCalls` on `algorithms.findBridges` returns callers including `edge_metrics.zig:138`
- [ ] `zig build test --summary all` passes
- [ ] `zig fmt --check .` passes

## Anti-Patterns

- NO redesigning Shape B during SRE. The storage decision (per-handle lazy cache populated by `uriFromImportStr`) is pinned. SRE resolves: exact Zig type for the field, mutex ownership, precise invalidation insertion point. SRE does NOT substitute Shape A or any third alternative.
- NO duplicating resolution logic. The only way URIs enter `resolved_imports` is via `uriFromImportStr`. Do not re-walk ASTs in reference search looking for `@import` strings.
- NO extending `file_imports` to include modules. Its docstring at `DocumentStore.zig:166` says "Does not include imported modules" — that contract stands. Module imports live in the new field.
- NO making resolved-imports populate synchronously at parse time. The design premise is that module resolution needs build config, which is async. Lazy population is the whole point.
- NO skipping the forge demo re-run. The test suite may pass in isolation while the real-world case still fails (as it did before this task). Forge is the acceptance gate.

## Key Considerations

- **Build-config-ready event:** `uriFromImportStr` can return `.none` if build config isn't resolved when called. In that case, nothing gets cached. Subsequent calls (after the build finally resolves) cache successfully. No special "kick" needed — the cache fills as analysis exercises handles.
- **Concurrent mutation:** `uriFromImportStr` is called from multiple analyser contexts (hover, goto, completion, references). The resolved-imports set MUST tolerate concurrent insert. `DocumentStore.Handle` already has `impl.mutex` — reuse it or add a sibling mutex scoped to this field.
- **Deduplication:** if a file has 100 call sites of `@import("foo")`, we resolve 100 times but the set only stores the URI once. That's fine — `uriFromImportStr` is already memoized-ish via the store's handle cache.
- **`std`/`builtin` pollution:** every file imports `std`, so `resolved_imports` will contain the std.zig URI for nearly every handle. Candidate discovery walking this edge means reverse search on `std` symbols would balloon the candidate set. Guard: if candidate discovery is called on a target in the zig std library, skip adding the std root to candidates (or add a bounded limit). SRE to decide the exact guard shape.
- **`isInStd` check:** the existing `isAssociatedWith` helper at DocumentStore.zig:142 already has `if (isInStd(source_uri)) continue;` — follow that precedent in the fallback iteration.
- **Test infra reuse:** Problem B (zls-029) will likely want the same test helper. Design it reusable from the start.

## Dependencies

Blocks: zls-pun (Phase 2 acceptance).
Parent: zls-gyi.
