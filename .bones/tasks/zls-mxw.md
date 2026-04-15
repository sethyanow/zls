---
id: zls-mxw
title: 'Phase 2 Task 4: Module-import coverage in reverse reference search'
status: active
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
- R-M6 (scope extension 2026-04-15): `incomingCalls` / `findReferences` on a **definition** in a multi-module project with a resolved BuildConfig must find callers that import the target's module by name. Shape B alone (walk `resolved_imports` forward from `root_handle`'s single module root) is insufficient when `root == target` — reverse callers in other modules are structurally unreachable. Fix: seed the build-system path's forward walk from **all** module roots in `build_config.modules.map`, mirroring the existing `DocumentStore.BuildFile.isAssociatedWith` pattern at `src/DocumentStore.zig:95-152`.
- R-M7: Dedicated std-pollution regression test. The `isInStd` guard in `gatherWorkspaceReferenceCandidates` (implemented in this task) has no explicit test. Add one: seed a handle's `resolved_imports` with the std URI, verify the candidate set does not recurse into std files.

## Implementation Steps

1. **Test helper** — add a helper in `tests/context.zig` (or a new `tests/helper_build.zig`) that constructs a `std.json.Parsed(BuildConfig)` from a JSON string and attaches it to a fake `BuildFile`, then stamps handles' `associated_build_file` to `.resolved`. Pattern already exists for `.unresolved` at `tests/lsp_features/references.zig:1119-1142`; extend it to also populate `impl.config`. ~30-50 LOC.

2. **New fixture** — `tests/fixtures/module_imports/` with a `build.zig` defining two modules (e.g., `mod_a` with root `a.zig`, `mod_b` with root `b.zig`) where `a.zig` does `@import("mod_b")` and calls into `b.zig`. The build.zig is real (won't be executed, but its shape drives the JSON we construct in the helper).

3. **Failing test first (TDD)** — in `tests/lsp_features/references.zig`: load the module_imports fixture via the helper with a populated resolved BuildConfig. From the symbol in `b.zig`, call `findReferences`. Expect the reference in `a.zig`. Test fails before implementation (empty result).

4. **Implementation** —
   - **Field** on `DocumentStore.Handle` (next to `file_imports`, line 167):
     ```zig
     /// Set of URIs that have been resolved through `uriFromImportStr` (covers
     /// module-name imports, `std`, `builtin`, `root`, build deps). Populated
     /// lazily. Guarded by `impl.lock`. Cleared in `Handle.refresh` on re-parse.
     resolved_imports: Uri.ArrayHashMap(void) = .empty,
     ```
     Unmanaged via `Uri.ArrayHashMap(V)` (defined at `Uri.zig:168-170` as `std.ArrayHashMapUnmanaged(Uri, V, Context, true)`). Allocator passed on each mutation is `store.allocator`.
   - **Mutex**: reuse existing `impl.lock` (`std.Io.Mutex`, DocumentStore.zig:180). `uriFromImportStr` acquires/releases briefly for the cache insert only. Safe because caching happens AFTER `getAssociatedBuildFile`/`tryLockConfig` have returned and released their locks — no re-entrance.
   - **Caching in `uriFromImportStr`** (DocumentStore.zig:2026): at each `.one`/`.many` return site, before returning, dupe the URI(s) with `store.allocator`, take `handle.impl.lock`, insert via `handle.resolved_imports.put(store.allocator, duped_uri, {})` (O(1) dedup — if already present, free the dupe), release. Return paths to cover: line 2037 (direct .zig/.zon), 2046 (std), 2055 (builtin via build), 2061 (builtin via config), 2081 (root, `.many`), 2090 (build dep), 2103 (named module). Skip `.none` returns.
   - **Candidate walk union** in `src/features/references.zig` `gatherWorkspaceReferenceCandidates`:
     - Build-system path (around line 370, after the `handle.file_imports` loop): walk `handle.resolved_imports.keys()`, skip via `if (DocumentStore.isInStd(uri)) continue;` precedent (DocumentStore.zig:142/1508/1621), dupe via arena (matching the file_imports dupe at DocumentStore.zig:147), put into `found_uris`.
     - Fallback path (around line 379 inside the `while (it.next())` loop): same union pattern, feeding `per_file_dependants`.
   - **Invalidation** in `Handle.refresh` (DocumentStore.zig:406 — skeleton previously said `updateFileAndTree`, that function does not exist; the real entry point is `refresh`). Follow the move-to-old_handle idiom used for `file_imports`/`cimports`/`document_scope`/`trigram_store`:
     ```zig
     // Between lines 460-461, alongside trigram_store swap:
     old_handle.resolved_imports = handle.resolved_imports;
     handle.resolved_imports = .empty;
     ```
     Add matching cleanup in `Handle.deinit` (line 562): loop freeing each URI via `store.allocator`, then `resolved_imports.deinit(allocator)`.

5. **Additional tests** —
   - Invalidation: mutate handle content, verify `resolved_imports` cleared on re-parse, new resolution re-populates.
   - Unresolved build config: resolved-imports stays empty; fallback via `file_imports` still works for any file-path imports in the fixture (regression guard).
   - Cross-module call hierarchy: `incomingCalls` on a function in `b.zig` finds the call site in `a.zig`.
   - Std pollution regression: walking a handle whose `resolved_imports` contains the std URI does NOT cause `gatherWorkspaceReferenceCandidates` to recurse into std (candidate set size bounded).

6. **Definition-query seed fix (R-M6)** — in `src/features/references.zig` `gatherWorkspaceReferenceCandidates` build-system path (current L336-393):

   Replace the narrow seed (`root_module_root_uri` + optional `target_module_root_uri`) with an all-modules seed derived from `build_config.modules.map.keys()`. Lock the build config via `tryLockConfig` (precedent: DocumentStore.zig:119, 1810, 1852, 2146). If `tryLockConfig` returns null, `break :no_build_file` — same safety pattern as `.unresolved`.

   ```zig
   var found_uris: Uri.ArrayHashMap(void) = .empty;
   {
       const build_config = resolved.build_file.tryLockConfig(store.io) orelse break :no_build_file;
       defer resolved.build_file.unlockConfig(store.io);

       const module_paths = build_config.modules.map.keys();
       try found_uris.ensureUnusedCapacity(arena, module_paths.len);
       for (module_paths) |module_path| {
           const uri: Uri = try .fromPath(arena, module_path);
           found_uris.putAssumeCapacity(uri, {});
       }
   }
   // Forward walk body unchanged (file_imports + resolved_imports union with isInStd guard).
   ```

   Delete the now-redundant root/target module seed blocks. The forward-walk loop body (file_imports union + resolved_imports snapshot with isInStd skip) stays identical.

7. **Forge demo re-run** — after implementation, re-run `incomingCalls` on `algorithms.findBridges` at `forge_worktrees/optimize/zig/forge_graph_zig/src/algorithms.zig:164`. Expected: the call site in `edge_metrics.zig:138` appears. Forge's build.zig declares `src/edge_metrics.zig` as its own module root (L321), so seeding from all module roots makes it immediately visible.

8. **Verify all tests pass** — `zig build test --summary all`, `zig build check`, `zig fmt --check .`.

## Success Criteria

- [ ] New test fixture `tests/fixtures/module_imports/` checked in with build.zig + multi-module structure
- [ ] Test helper for constructing a fake resolved BuildConfig added and reusable
- [ ] TDD: failing test precedes implementation for each requirement (R-M1 through R-M7)
- [ ] `resolved_imports` field added to `DocumentStore.Handle`, thread-safe
- [ ] `uriFromImportStr` populates `resolved_imports` on successful resolution across all paths
- [ ] `gatherWorkspaceReferenceCandidates` both paths union `resolved_imports` into candidate set
- [ ] Build-system path seeds from **all** module roots in resolved BuildConfig (R-M6), not just root/target module roots
- [ ] Invalidation on re-parse — resolved_imports moved to old_handle in `Handle.refresh`, freed in `Handle.deinit`
- [ ] Cross-module findReferences test passes (call-site query)
- [ ] Definition-query test passes (cursor on target definition, caller imports by module name, resolved BuildConfig)
- [ ] Invalidation test passes
- [ ] Unresolved-build regression test passes
- [ ] Std pollution regression test passes (candidate set stays bounded when `resolved_imports` contains std URI) — R-M7
- [ ] No memory leaks reported by the test allocator (`std.testing.allocator`) — covers dedup `getOrPut` pattern and all URI dupes
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
- **Concurrent mutation:** `uriFromImportStr` is called from multiple analyser contexts (hover, goto, completion, references). The resolved-imports set MUST tolerate concurrent insert. Resolved: reuse `impl.lock` (`std.Io.Mutex`, DocumentStore.zig:180). Cache insertion happens AFTER `getAssociatedBuildFile`/`tryLockConfig` have returned, so re-entrance on `impl.lock` is avoided.
- **`std`/`builtin` pollution:** every file imports `std`, so `resolved_imports` will contain the std.zig URI for nearly every handle. Candidate discovery walking this edge means reverse search on `std` symbols would balloon the candidate set. Guard: in `gatherWorkspaceReferenceCandidates`, skip URIs satisfying `DocumentStore.isInStd(uri)` when unioning `resolved_imports`. Precedent: DocumentStore.zig:142 (`isAssociatedWith`), :1508, :1621.
- **Test infra reuse:** Problem B (zls-029) will likely want the same test helper. Design it reusable from the start.

### Adversarial Failure Catalog

**Handle.refresh swap race (State Corruption + Temporal)**
- Assumption: `Handle.refresh`'s field swaps happen with no concurrent readers/writers of the handle.
- Betrayal: `resolved_imports` has a different concurrency model than the other swapped fields — it's mutated by any analyser task calling `uriFromImportStr` at any time. `refresh` today holds no lock.
- Consequence: Mid-swap `put` corrupts map internals transferred to `old_handle` → UAF/crash.
- Mitigation: `Handle.refresh` MUST acquire `handle.impl.lock` around JUST the `resolved_imports` move (`old_handle.resolved_imports = handle.resolved_imports; handle.resolved_imports = .empty;`). Existing field swaps stay un-locked; this one field is the exception.

**Dedup leak via naive `put` (State Corruption)**
- Assumption: `ArrayHashMap.put` with existing key is free.
- Betrayal: We dupe the URI with `store.allocator` before insertion. If key exists, `put` keeps the original key and drops ours → leak of the duped bytes.
- Consequence: Per-call memory leak; unbounded over many resolutions.
- Mitigation: `getOrPut` pattern — on `found_existing`, free the dupe with `store.allocator`. Otherwise the map owns the key.

**uriFromImportStr lock re-entrance invariant (Dependency Treachery)**
- Assumption: No caller of `uriFromImportStr` holds `handle.impl.lock`.
- Betrayal: `std.Io.Mutex` is not re-entrant. Reusing `impl.lock` for cache insert creates an implicit invariant future code can silently violate (e.g., a refactor that calls `uriFromImportStr` from inside `getAssociatedBuildFile`-adjacent code).
- Consequence: Deadlock; hard to debug.
- Mitigation: Doc comment above `uriFromImportStr` — "Caller MUST NOT hold `handle.impl.lock`." Matches the existing "Thread safe" doc style at line 2025.

**Candidate-walk iteration vs concurrent put (State Corruption)**
- Assumption: `resolved_imports.keys()` is stable for the walk.
- Betrayal: Concurrent `put` grows the map → array reallocates → `keys()` slice dangles.
- Consequence: UAF.
- Mitigation: Snapshot under lock before walking:
  ```zig
  try handle.impl.lock.lock(store.io);
  const snapshot = try arena.dupe(Uri, handle.resolved_imports.keys());
  handle.impl.lock.unlock(store.io);
  for (snapshot) |uri| { if (DocumentStore.isInStd(uri)) continue; ... }
  ```

**Stale cache on build-config change without re-parse (Temporal)**
- Assumption: Cache invalidation on handle re-parse catches all staleness.
- Betrayal: `build.zig` change → build runner re-runs → new module graph, but no `.zig` source re-parses. Old `resolved_imports` retained.
- Consequence: Reverse search may find spurious candidates or miss new edges.
- Mitigation: Known limitation for this task. Bounded impact (no crash; next handle re-parse rebuilds its own cache). Follow-up task could add an invalidation hook on build config reload — OUT OF SCOPE here.

**Fixture path encoding in test helper (Dependency Treachery)**
- Assumption: JSON paths match the URIs ZLS computes from the fixture.
- Betrayal: Hardcoded relative paths or Windows-path slashes → `modules.map.get(root_source_file)` returns null → `.none` resolution → test fails with misleading "reference not found" (test infra broken, not feature broken).
- Consequence: False-negative test signal; implementation could be correct while CI reports it broken.
- Mitigation: Helper accepts the fixture's absolute root path at runtime and templates it into the JSON; use `std.fs.realpath` + `Uri.fromPath` for consistency with ZLS's path handling.

## Dependencies

Blocks: zls-pun (Phase 2 acceptance).
Parent: zls-gyi.

## Log

- [2026-04-15T13:39:27Z] [Seth] Implementation complete. All 3 new tests pass (build-system path, fallback path, invalidation). Full suite 651/662 green, zig fmt clean.

FORGE DEMO BLOCKER: (1) killed zls processes to force binary reload, LSP tool stuck at 'server is running' - user may need to restart. (2) Analysis of walk direction reveals Shape B's fix is insufficient for incomingCalls-from-definition scenario in multi-module projects with resolved BuildConfig. Build-system path does forward walk from root_handle's module root; when root=target=algorithms_handle in forge, walk starts at algorithms.zig module root, resolved_imports adds graph/topology/etc (forward deps), but edge_metrics.zig is NOT reachable forward - it's a reverse caller. Fix works for (a) cursor on CALL SITE (root != target, target module root added to walk), or (b) fallback path (reverse walk). Does NOT work for cursor on DEFINITION with resolved build.

SCOPE DECISION NEEDED from user: accept this limitation and ship, or extend scope to fix definition-query case (would need isAssociatedWith or gatherWorkspaceReferenceCandidates seed enhancement).
- [2026-04-15T17:01:32Z] [Seth] Scope extension approved 2026-04-15: adding R-M6 (definition-query in multi-module builds) and R-M7 (std-pollution regression test). Option A chosen for R-M6: seed gatherWorkspaceReferenceCandidates build-system path from all modules in resolved BuildConfig (build_config.modules.map.keys()), mirroring isAssociatedWith pattern at DocumentStore.zig:95-152. Forge ground truth: edge_metrics.zig declared as module at build.zig:321, algorithms.zig at build.zig:308 — seeding from all roots immediately includes both, fixing the cursor-on-definition case. Alternatives rejected: Option B (unify reverse-dependants, 50+ LOC refactor, loses build-scoping), Option D (force fallback for definition queries, loses build-scoping entirely). TDD: two new failing tests required before impl.
