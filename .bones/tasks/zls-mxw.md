---
id: zls-mxw
title: 'Phase 2 Task 4: Module-import coverage in reverse reference search'
status: closed
type: task
priority: 1
parent: zls-gyi
---



## Context

`incomingCalls` / `findReferences` on a function defined in a module-imported file returned empty when the caller imported by module name (`@import("mod_b")`) rather than file path (`@import("b.zig")`). Surfaced by Phase 2 acceptance work.

**Mechanical cause:**
- `src/DocumentStore.zig:519` — `collectImports` filters non-`.zig` imports by design; `handle.file_imports`'s docstring at line 166 explicitly says "Does not include imported modules".
- `src/features/references.zig` — both paths of `gatherWorkspaceReferenceCandidates` iterated only `handle.file_imports`. Module-resolved edges were invisible to the candidate-discovery walk.
- Resolution mechanism already existed: `DocumentStore.uriFromImportStr` (`src/DocumentStore.zig:2061`) handles `.zig` paths, `std`, `builtin`, `root`, build.zig dependencies, and full `build_config.modules.import_table` lookups. Nothing new to invent — just observe its results.

## Design

**Shape B: cache resolved module URIs on `Handle` lazily.**

A per-handle set holds URIs resolved through `uriFromImportStr`. Populated opportunistically whenever analysis resolves an import. Read by both reverse-search paths alongside `file_imports`.

Rationale:
- Respects the existing contract on `file_imports` (file-path imports only, populated at parse time).
- Single source of resolution truth. `uriFromImportStr` is the only function that knows how module names become URIs — caching its results rather than duplicating the resolution logic keeps the codebase coherent.
- Composes with the existing fallback philosophy. First reference call may be incomplete if the build config hasn't resolved yet; subsequent calls see the cached edges.

**R-M6 addendum:** Shape B alone is insufficient when cursor lands on a definition in a multi-module project and `root == target`. The build-system path's forward walk starts at the single root module root; reverse callers in other modules are structurally unreachable. Fix: seed the forward walk from **all** module roots in `build_config.modules.map`, mirroring the pattern at `DocumentStore.BuildFile.isAssociatedWith` (`src/DocumentStore.zig:95-152`).

## Requirements

- **R-M1** — Lazily-populated set of resolved import URIs accessible per-`Handle`. Thread-safe against concurrent `uriFromImportStr` callers.
- **R-M2** — Every successful `uriFromImportStr` call records its result in the calling handle's set. Covers the entire resolution surface (`.zig` paths, `std`, `builtin`, `root`, build deps, named modules).
- **R-M3** — Both paths of `gatherWorkspaceReferenceCandidates` (build-system and fallback) include resolved-import edges alongside `file_imports`.
- **R-M4** — Invalidation: when a handle's tree is replaced (re-parse), its resolved-imports set is cleared. Matches the lifecycle of `file_imports`.
- **R-M5** — Fixture + tests exercising module-name imports end-to-end. `tests/fixtures/eager_load/` covers file-path imports only and can't reach this case.
- **R-M6** — In a multi-module project with a resolved BuildConfig, `incomingCalls` / `findReferences` on a **definition** finds callers that import the target's module by name. Build-system path seeds from all module roots in `build_config.modules.map`, not just root/target.
- **R-M7** — Std-pollution regression: when a handle's `resolved_imports` contains the std URI, the candidate set returned by `gatherWorkspaceReferenceCandidates` does not recurse into std files.

## Implementation (as delivered)

1. **Field** — `DocumentStore.Handle.resolved_imports: Uri.ArrayHashMap(void)` at `src/DocumentStore.zig:173`. Docstring notes concurrency model (guarded by `impl.lock`), lifecycle (cleared on re-parse), and ownership (URIs duped with `store.allocator`).

2. **Caching** — `cacheResolvedImport` at `src/DocumentStore.zig:575`. `getOrPut` avoids a dedup leak: on `found_existing`, frees the duped URI; otherwise the map owns it. Acquires `handle.impl.lock` briefly around the insert.

3. **Population** — `uriFromImportStr` at `src/DocumentStore.zig:2061` calls `cacheResolvedImport` at every successful `.one` / `.many` return site (`.zig` direct paths, `std`, `builtin` via build, `builtin` via config, `root` many, build deps, named modules).

4. **Re-parse invalidation** — `Handle.refresh` at `src/DocumentStore.zig:468-474`. Swap happens under `impl.lock` — unlike the other field swaps in refresh — because `resolved_imports` is the only refreshed field mutated by non-refresh tasks.

5. **Deinit** — `Handle.deinit` at `src/DocumentStore.zig:607-608`. Frees every owned URI, then the map itself.

6. **Candidate walk union — build-system path** — `src/features/references.zig:383-401`. Snapshots `handle.resolved_imports.keys()` under the handle's lock, then walks the snapshot with an `isInStd` skip. Runs after the `file_imports` loop at the same nesting level.

7. **Candidate walk union — fallback path** — `src/features/references.zig:422-438`. Same snapshot-under-lock pattern, feeding the per-file dependants map.

8. **R-M6 seed** — `src/features/references.zig:359-372`. Build-system path acquires `tryLockConfig`, iterates `build_config.modules.map.keys()`, seeds `found_uris` with every module root. `tryLockConfig` null → `break :no_build_file`, falling through to the fallback path (same safety semantics as `.unresolved`).

9. **Test helper** — `tests/helper_build.zig`. `makeResolved` parses a JSON string into `std.json.Parsed(BuildConfig)` and wraps it in a fake `BuildFile`. `stampResolved` stamps a handle's `associated_build_file` to `.resolved` pointing at that BuildFile. Reusable from zls-029.

10. **Fixture** — `tests/fixtures/module_imports/{build.zig,a.zig,b.zig}`. Two-module graph: `mod_a` root `a.zig` imports `mod_b` root `b.zig` by module name and calls `b.doubled`. The `build.zig` is not executed — its shape drives the JSON fed through the helper.

11. **Tests** — `tests/lsp_features/references.zig`:
    - `findReferences across module-name import, fallback path (zls-mxw)` (line 1232) — R-M1, R-M2, R-M3 (fallback).
    - `resolved_imports cleared on handle re-parse (zls-mxw R-M4)` (line 1364) — R-M4.
    - `findReferences across module-name import, build-system path (zls-mxw)` (line 1456) — R-M3 (build-system).
    - `findReferences on definition with module-name callers, build-system path (zls-mxw R-M6)` (line 1600) — R-M6.
    - `gatherWorkspaceReferenceCandidates skips std when resolved_imports contains std URI (zls-mxw R-M7)` (line 1737) — R-M7.

## Success Criteria

- [x] Fixture `tests/fixtures/module_imports/` in repo with build.zig + two-module structure
- [x] Test helper `tests/helper_build.zig` reusable across zls-mxw and zls-029
- [x] `resolved_imports` added to `DocumentStore.Handle`, thread-safe under `impl.lock`
- [x] `uriFromImportStr` populates `resolved_imports` on every successful resolution path
- [x] `gatherWorkspaceReferenceCandidates` both paths union `resolved_imports` into the candidate set
- [x] Build-system path seeds from all module roots in resolved BuildConfig (R-M6)
- [x] Invalidation on re-parse — map moved to `old_handle` under lock, freed in `deinit`
- [x] Cross-module findReferences passes from a call-site cursor (fallback + build-system)
- [x] Definition-cursor findReferences passes in a multi-module resolved BuildConfig (R-M6)
- [x] Invalidation test passes
- [x] Std-pollution regression test passes (R-M7)
- [x] No leaks reported by `std.testing.allocator` across the five tests
- [x] `zig build test --summary all` green — 57/57 steps, 653/664 tests, 11 skipped, 0 failed
- [x] `zig fmt --check .` clean

## Anti-Patterns

- **NO duplicating resolution logic.** The only entry point for URIs into `resolved_imports` is `uriFromImportStr`. Do not re-walk ASTs in reference search looking for `@import` strings.
- **NO extending `file_imports` to include modules.** Its docstring at `DocumentStore.zig:166` says "Does not include imported modules" — that contract stands. Module imports live in the new field.
- **NO synchronous parse-time population.** Module resolution needs the build config, which is async. Lazy population is the point.
- **NO third seed of the build-system walk.** R-M6's fix is "seed from all module roots"; earlier partial fixes seeded root+target only. Do not regress to that — it misses reverse callers when cursor is on the definition.

## Key Considerations

- **Build-config-unready callers:** `uriFromImportStr` returns `.none` if build config isn't resolved. Nothing gets cached in that call. Subsequent calls, after the build resolves, cache successfully. No "kick" needed — the cache fills as analysis exercises handles.
- **Concurrent mutation:** `uriFromImportStr` is called from multiple analyser contexts (hover, goto, completion, references). The resolved-imports set tolerates concurrent insert via `impl.lock`.
- **`std`/`builtin` pollution:** every file imports `std`. Unioning `resolved_imports` into the candidate walk would balloon the candidate set for any user-code symbol. The `isInStd` guard in both paths of `gatherWorkspaceReferenceCandidates` skips those URIs. R-M7 is the dedicated regression test.
- **Lock re-entrance:** `std.Io.Mutex` is not re-entrant. `cacheResolvedImport` acquires `impl.lock` AFTER any `getAssociatedBuildFile` / `tryLockConfig` calls have returned and released their own locks. Callers of `uriFromImportStr` must not hold `impl.lock`.
- **Dedup leak avoidance:** `cacheResolvedImport` uses `getOrPut` and frees the duped URI when `found_existing`. A naive `put` would leak the dupe on every hit.
- **Snapshot for walking:** `resolved_imports.keys()` is copied into the arena under `impl.lock` before the walk, so a concurrent `put` can't realloc the backing array during iteration.
- **Stale cache on build-config reload:** a `build.zig` change that re-runs the build runner without re-parsing `.zig` sources leaves old `resolved_imports` entries. Bounded impact (no crash; next re-parse rebuilds). Out of scope here — noted for any follow-up.

## Dependencies

Parent: zls-gyi.
Blocks: zls-pun.

## Log

- [2026-04-15T20:39:59Z] [Seth] Debrief (verification session): tests re-run fresh — 653/664 passed (11 skip, 0 fail), 57/57 steps succeeded, zig fmt --check clean. Prior agent's claims verified.

Technical debrief:
- Workarounds: none fragile. Noted limitation (Key Considerations): stale cache on build-config reload without re-parse — bounded, out-of-scope for this task.
- Design decisions that emerged mid-task: R-M6 scope extension (seed-all-modules for definition-cursor incomingCalls) + R-M7 (std-pollution regression test). User approved Option A over alternatives B (50+ LOC refactor) and D (force fallback).
- Toolchain surprises: std.Io.Mutex non-re-entrance forced cacheResolvedImport to acquire impl.lock strictly after all tryLockConfig/getAssociatedBuildFile calls have released. getOrPut + dedup-on-found_existing needed to avoid URI-dupe leak.
- What next task (zls-029) inherits: tests/helper_build.zig (makeResolved, stampResolved) — already cited in zls-029 skeleton. tests/fixtures/module_imports/ reusable. gatherWorkspaceReferenceCandidates now includes resolved_imports edges, so zls-029's candidate walk sees module-name-imported files.

Reflection:
- Skeleton accuracy: required R-M6 addendum mid-task when adversarial review showed Shape B alone didn't cover incomingCalls-from-definition in multi-module resolved-BuildConfig projects. Skeleton was amended in-flight.
- Epic freshness: sub-epic zls-gyi only unchecked criterion is the live LSP demo (acceptance task zls-pun). Parent epic zls-xjj has two unchecked: findReferences cross-file coverage demo + live demo — both belong to acceptance.
- Cross-pollination: helper_build.zig + module_imports fixture are reusable infra for any future build-config-dependent test.
- User correction: scope extension approved 2026-04-15 — chose fix-now over ship-with-limitation.

Memory cycle: no new memory files — all findings are project-specific and captured in code/skeletons.

Closure commit: 74e593be.
