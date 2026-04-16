---
id: zls-ez6
title: gatherWorkspaceReferenceCandidates build-system path drops loaded handles not in module graph
status: open
type: bug
priority: 1
parent: zls-gyi
---





## Context

`gatherWorkspaceReferenceCandidates` (`src/features/references.zig:330`) has two paths:

1. **Build-system path** (line 338-403): seeds from module roots in `BuildConfig`, walks forward via `file_imports` + `resolved_imports`.
2. **Fallback path** (line 406+): iterates ALL loaded handles via `HandleIterator`, builds reverse dependency map.

These paths are **mutually exclusive** — if the build config resolves, only the build-system path runs. This means files that are loaded in the DocumentStore but NOT reachable from any module root in `build.zig` are silently dropped from the candidate set.

## Reproduction

Using `tests/fixtures/module_imports/`:
- `a.zig` — module root (`mod_a`), imports `@import("mod_b")`
- `b.zig` — module root (`mod_b`), defines `doubled()`
- `c.zig` — NOT a module root, imports `@import("b.zig")`, calls `doubled()`

Query: `incomingCalls` on `doubled` in `b.zig`.

1. **First query** (build runner still running, config not ready): falls through to fallback path → finds `c.zig:wrap` as caller. Correct.
2. **Second query** (build config resolved): uses build-system path, seeds from module roots `a.zig` and `b.zig` → finds `a.zig:entry` but NOT `c.zig:wrap`. `c.zig` is loaded but unreachable from module roots.

Result: having a build config produces FEWER results than not having one. The build-system path should be a superset of the fallback, not a replacement.

## Requirements

- R1: When the build-system path resolves, its candidate set must include all handles that the fallback path would have found — the build-system path must be a superset, not a replacement.
- R2: No regression in existing findReferences, incomingCalls, or outgoingCalls behavior for files that ARE module roots.

## Success Criteria

- [ ] `incomingCalls` on `doubled` in `b.zig` returns BOTH `a.zig:entry` (module-name import) and `c.zig:wrap` (file-path import) when the build config is resolved
- [ ] Existing references.zig and call_hierarchy.zig tests pass
- [ ] No performance regression from unioning candidate sets (build-system seeds + loaded handles)

## Design Direction

Union the two strategies instead of choosing one. After the build-system forward walk completes, also iterate loaded handles via `HandleIterator` and add any that aren't already in `found_uris`. This preserves the build-system path's module-root seeding (which discovers unloaded files) while also including loaded files that aren't part of the module graph.

Sketch at `references.zig:338`:
```
// After build-system forward walk (line 402):
// Union with loaded handles so files open in the editor but not
// in the module graph are still searched.
var it: DocumentStore.HandleIterator = .{ .store = store };
while (it.next()) |handle| {
    try found_uris.put(arena, handle.uri, {});
}
return found_uris;
```

## Log

- [2026-04-16T06:40:00Z] [Seth] Filed from acceptance demo. Build-system candidate path (references.zig:338-403) replaces the fallback HandleIterator path instead of unioning with it. Fix: after build-system forward walk, also iterate loaded handles so open files outside the module graph are still searched.
