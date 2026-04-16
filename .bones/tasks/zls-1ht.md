---
id: zls-1ht
title: gatherWorkspaceReferenceCandidates forward walk cannot follow cold resolved_imports edges
status: open
type: bug
priority: 1
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

- [ ] `findReferences` on a function in a source module finds callers in test files that import the module by name, without the test files needing to be opened or analyzed first
- [ ] Existing references.zig and call_hierarchy.zig tests pass
- [ ] The fix uses `BuildConfig.modules.map` data during the forward walk, not a new eager-warming mechanism

## Design Direction

During the forward walk at `references.zig:376-402`, for each module root URI, look up its entry in `build_config.modules.map` and add the `import_table` values directly to `found_uris`. This uses data already available in the locked `BuildConfig` — no new loading, no new caching, no analysis required.

Sketch — extend the forward walk loop body (after `resolved_imports` snapshot at line 396):
```zig
// Fall back to the BuildConfig's import_table for module roots
// whose resolved_imports haven't been warmed by analysis yet.
// The build runner already extracted the full module map —
// use it directly instead of depending on the lazy cache.
if (handle.resolved_imports.count() == 0) {
    const build_config = resolved.build_file.tryLockConfig(store.io) orelse continue;
    defer resolved.build_file.unlockConfig(store.io);
    const uri_path = try Uri.toPath(arena, uri);
    if (build_config.modules.map.get(uri_path)) |mod| {
        for (mod.import_table.map.values()) |import_path| {
            const import_uri: Uri = try .fromPath(arena, import_path);
            if (DocumentStore.isInStd(import_uri)) continue;
            try found_uris.put(arena, import_uri, {});
        }
    }
}
```

Note: the config is already locked once at line 364-372 for the initial seed. The forward walk releases it before iterating. Re-locking per-handle is safe but could be optimized by keeping the lock longer or snapshotting import_table values during the initial seed phase.

Alternative: warm `resolved_imports` eagerly by calling `uriFromImportStr` for each import in the build config during `loadBuildConfiguration`. This would fix the cold-cache problem at the source but adds work to the build runner completion path. The sketch above is cheaper — reads existing data, no new resolution.

## Log

- [2026-04-16T08:30:00Z] [Seth] Found during live testing against a real Zig codebase using exclusively module-name imports. Build runner output confirmed correct (test modules with full import_table). Forward walk from test file module roots follows zero edges because resolved_imports is cold. The data to fix this already exists in BuildConfig.modules.map.
