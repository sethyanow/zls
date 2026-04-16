---
id: zls-1ht
title: gatherWorkspaceReferenceCandidates forward walk cannot follow cold resolved_imports edges
status: closed
type: bug
priority: 1
owner: Seth
parent: zls-gyi
---







## Context

`gatherWorkspaceReferenceCandidates` (`src/features/references.zig:330`) seeds its forward walk from ALL module roots in the resolved `BuildConfig`, then walks forward via `file_imports` (line 381) and `resolved_imports` (line 389-401). This correctly discovers files connected by both file-path and module-name imports — **but only if `resolved_imports` has been populated**.

`resolved_imports` is a lazy cache on `Handle`, populated by `uriFromImportStr` during analysis operations (hover, goto, completion). For module roots whose handles have never been analyzed — e.g. test files the user hasn't opened — `resolved_imports` is empty. The forward walk from those files discovers nothing, even though the build config's `import_table` has the exact mapping.

The build runner correctly extracts test artifact modules. A test file like `test/scoring_tests.zig` appears in `BuildConfig.modules` with a full `import_table` mapping `"scoring" → "src/scoring.zig"`. But at runtime, the forward walk from `scoring_tests.zig` sees an empty `resolved_imports` and follows zero edges.

Result: `findReferences` and `incomingCalls` on a function defined in a source module miss all callers in test files (and any other module-name-importing file that hasn't been analyzed yet). In a codebase that uses exclusively module-name imports (no `.zig` file paths), cross-file references are invisible until the user manually opens and hovers over every importing file.

## Reproduction

Any Zig project where:
1. `build.zig` defines test modules via `addTest` with module-name imports (e.g. `@import("scoring")`)
2. The build runner succeeds and produces correct `import_table` entries for test modules
3. The user opens a source file but NOT the test files
4. `findReferences` or `incomingCalls` on a function in the source file returns zero results from test files

Verified: the build runner output includes the test file as a module root with correct `import_table`. The data exists in the `BuildConfig` — it's just not used during the forward walk because `resolved_imports` is cold.

## Requirements

- R1: The build-system forward walk must discover import edges from the `BuildConfig.import_table` when a module root's `resolved_imports` cache is empty. The build config already has the mapping — the forward walk should read it directly instead of depending on a lazy cache that requires prior analysis.
- R2: No regression in existing behavior for files with warm `resolved_imports` — the build config fallback supplements, not replaces, the lazy cache.

## Success Criteria

- [x] Regression test: `findReferences` on a function in a source module finds callers in test files that import the module by name, without the test file's `resolved_imports` needing to be warmed first
- [x] Existing references.zig and call_hierarchy.zig tests pass (`zig build test --summary all`)
- [x] The fix snapshots `BuildConfig.modules.map` import_table data during the seed phase and uses it during the forward walk — no new eager-warming mechanism, no per-handle config re-locking

## Anti-Patterns

- DO NOT guard the import_table fallback with `resolved_imports.count() == 0` — `resolved_imports` can be partially warm (some but not all module-name imports resolved). The guard would skip the fallback when it's still needed. Always read import_table for module roots; `found_uris.put` deduplicates.
- DO NOT re-lock the config inside the forward walk per-handle — snapshot import_table values during the initial seed phase (lines 363-373) while the config IS locked.
- DO NOT use `Uri.toPath` — that function does not exist. Use `uri.toFsPath(arena)` which returns `error{UnsupportedScheme, OutOfMemory}![]u8`.
- DO NOT warm `resolved_imports` eagerly — the fix reads existing BuildConfig data, no new resolution needed.

## Design Direction

Snapshot import_table values during the initial seed phase (references.zig:363-373), while the BuildConfig is already locked. For each module root, convert its import_table values (file paths) to URIs and store them. Then during the forward walk (lines 375-402), after processing `file_imports` and `resolved_imports`, also add the snapshotted import_table URIs for that module root.

### Why snapshot during seed, not re-lock per handle

The config lock is already held at lines 364-365. Snapshotting here avoids:
1. Re-acquiring the lock N times during the walk (once per module root)
2. Risk of the config changing between seed and walk (another thread could update)
3. URI↔path round-trip per handle (seed already does path→URI conversion)

### Implementation approach

**Step 1: Snapshot import_table during seed phase.** Inside the existing config-locked block (lines 363-373), build a second map: `Uri.ArrayHashMap([]Uri)` mapping each module root URI to an array of its import_table values (converted to URIs, std-filtered). This uses arena allocation.

**Step 2: Use snapshot in forward walk.** After the `resolved_imports` snapshot processing (line 401), look up the current `uri` in the import_table snapshot map. If found, add all values to `found_uris`.

### Types

- `BuildConfig.modules`: `std.json.ArrayHashMap(Module)` — key is `[]const u8` (root source file path)
- `Module.import_table`: `std.json.ArrayHashMap([]const u8)` — key is import name (e.g., "scoring"), value is file path (e.g., "src/scoring.zig")
- `Uri.fromPath(arena, path)` converts file path → URI
- `uri.toFsPath(arena)` converts URI → file path (returns `error{UnsupportedScheme, OutOfMemory}![]u8`)
- `found_uris.put(arena, uri, {})` is idempotent — deduplicates existing entries

### Sketch

Extend the seed phase (inside the config lock at line 364):
```zig
const build_config = resolved.build_file.tryLockConfig(store.io) orelse break :no_build_file;
defer resolved.build_file.unlockConfig(store.io);

const module_paths = build_config.modules.map.keys();
const module_values = build_config.modules.map.values();
try found_uris.ensureUnusedCapacity(arena, module_paths.len);

// Snapshot: for each module root, pre-convert its import_table
// values to URIs. The forward walk will add these alongside
// resolved_imports — covering cold caches without re-locking.
var import_table_snapshot: Uri.ArrayHashMap([]Uri) = .empty;
try import_table_snapshot.ensureTotalCapacity(arena, module_paths.len);

for (module_paths, module_values) |module_path, module| {
    const module_uri: Uri = try .fromPath(arena, module_path);
    found_uris.putAssumeCapacity(module_uri, {});

    const import_values = module.import_table.map.values();
    const import_uris = try arena.alloc(Uri, import_values.len);
    var count: usize = 0;
    for (import_values) |import_path| {
        const import_uri: Uri = try .fromPath(arena, import_path);
        if (DocumentStore.isInStd(import_uri)) continue;
        import_uris[count] = import_uri;
        count += 1;
    }
    import_table_snapshot.putAssumeCapacity(module_uri, import_uris[0..count]);
}
```

Then in the forward walk body, after `resolved_imports` processing (after line 401):
```zig
// Add import_table edges from the BuildConfig snapshot.
// This covers module-name imports for files whose
// resolved_imports haven't been warmed by analysis yet.
if (import_table_snapshot.get(uri)) |import_uris| {
    try found_uris.ensureUnusedCapacity(arena, import_uris.len);
    for (import_uris) |import_uri| {
        found_uris.putAssumeCapacity(import_uri, {});
    }
}
```

## Key Considerations

### import_table snapshot (seed phase)

**Temporal Betrayal: Config lock scope**
- Assumption: Snapshot captures a consistent view of all module import_tables
- Betrayal: Config lock is released after snapshotting. Another thread could update the config between seed and walk, making snapshot stale.
- Consequence: Forward walk uses stale import_table data — could miss newly added imports or follow removed ones.
- Mitigation: Structural — snapshot is a copy into arena, same as existing module root URI seeding. Staleness is bounded to one request; next request snapshots fresh. Consistent with existing design.

### Forward walk import_table lookup

**Input Hostility: Non-module-root URIs in walk**
- Assumption: Only module root URIs appear in the snapshot map
- Betrayal: Forward walk iterates ALL `found_uris` including non-root files discovered via `file_imports`. Looking up a non-root file returns null.
- Consequence: None — `get()` returning null is the correct no-op for non-root files.
- Mitigation: Structural — only module root paths are snapshot keys. Non-root files have no import_table in BuildConfig. The null return is correct behavior, not an error.

### Regression test

**Temporal Betrayal: Test vacuous pass risk**
- Assumption: `resolved_imports` is empty when the query runs, proving the import_table fallback works
- Betrayal: If any test setup step accidentally triggers `uriFromImportStr` (e.g., calling analysis functions, hover, goto), `resolved_imports` gets warmed silently. Test passes without exercising the fix.
- Consequence: False green — test doesn't verify the cold-cache path. Regression in snapshot code goes undetected.
- Mitigation: Assert `a_handle.resolved_imports.count() == 0` immediately before the query. This makes the test structurally dependent on the cold-cache condition.

## Implementation

1. Write a regression test in `tests/lsp_features/references.zig` that reproduces the cold-`resolved_imports` bug: open fixture files `a.zig` and `b.zig` from `tests/fixtures/module_imports/`, stamp both as resolved module roots with a two-module config (mod_a imports mod_b by name), do NOT call `uriFromImportStr` to warm `a_handle.resolved_imports`, run `findReferences` on `doubled` in `b.zig`, assert `a.zig` appears in the results. The key difference from the zls-ez6 regression test: zls-ez6 warms `resolved_imports` before the query; this test must NOT warm it — proving the build config fallback works.
2. Run the test — confirm it fails (a.zig not found because the forward walk sees empty `resolved_imports` and follows zero module-name edges).
3. Modify `gatherWorkspaceReferenceCandidates` in `src/features/references.zig`:
   a. In the seed phase (lines 363-373), while the BuildConfig is locked, snapshot each module root's import_table values as URIs into a `Uri.ArrayHashMap([]Uri)`.
   b. In the forward walk body (after `resolved_imports` processing at line 401), look up the current URI in the snapshot map and add any import_table URIs to `found_uris`.
4. Run the test — confirm it passes.
5. Run full test suite (`zig build test --summary all`) — confirm no regressions.
6. Run `zig fmt --check .` — confirm clean formatting.

## Log

- [2026-04-16T08:30:00Z] [Seth] Found during live testing against a real Zig codebase using exclusively module-name imports. Build runner output confirmed correct (test modules with full import_table). Forward walk from test file module roots follows zero edges because resolved_imports is cold. The data to fix this already exists in BuildConfig.modules.map.
